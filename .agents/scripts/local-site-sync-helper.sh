#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
set -euo pipefail

# local-site-sync-helper.sh — freshness-checked sync into a shared local
# test site (e.g. LocalWP wp-content/plugins/<slug>/), safe for parallel
# worktrees. See GH#33296.
#
# Usage:
#   local-site-sync-helper.sh sync --src <worktree> --dest <dir> \
#       [--exclude-from <file>] [--force]
#   local-site-sync-helper.sh status --dest <dir>
#
# The stamp file is kept OUTSIDE the synced folder, as a sibling of <dest>
# named ".<basename of dest>.synced-from.json", so rsync --delete never
# removes it and the next session can read who/what last deployed.

_LSSH_SELF="${BASH_SOURCE[0]:-${0:-}}"
_LSSH_DIR="${_LSSH_SELF%/*}"
# shellcheck source=./shared-constants.sh
# shellcheck disable=SC1091
source "${_LSSH_DIR}/shared-constants.sh"

LOG_PREFIX="LOCAL-SITE-SYNC"

readonly LSSH_STALE_WARNING_SECONDS=1800 # 30 minutes

lssh_usage() {
	cat <<'EOF'
Usage:
  local-site-sync-helper.sh sync --src <worktree> --dest <dir> [--exclude-from <file>] [--force]
  local-site-sync-helper.sh status --dest <dir>

sync:
  Refuses unless the source HEAD contains the default remote branch
  (origin/<default>), so a shared site can never be overwritten by an
  older or unmerged worktree. --force bypasses that check only.
  Warns if another worktree synced to the same destination within the
  last 30 minutes.

status:
  Prints the stamp recorded by the last successful sync: source worktree,
  branch, HEAD SHA, dirty flag, and time.
EOF
	return 0
}

# Resolve the stamp file path for a given destination directory.
# Kept as a sibling of <dest>, not inside it, so rsync --delete never
# touches it.
lssh_stamp_path() {
	local dest="$1"
	local dest_abs dest_parent dest_base
	dest_abs="${dest%/}"
	dest_parent="$(dirname "$dest_abs")"
	dest_base="$(basename "$dest_abs")"
	printf '%s/.%s.synced-from.json\n' "$dest_parent" "$dest_base"
	return 0
}

# Print the default remote branch name for the repo at $1 (worktree path).
# Falls back to "main" if it cannot be determined.
lssh_default_branch() {
	local repo_dir="$1"
	local ref=""
	ref=$(git -C "$repo_dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
	if [[ -n "$ref" ]]; then
		printf '%s\n' "${ref#origin/}"
		return 0
	fi
	printf 'main\n'
	return 0
}

# Write the stamp file for a completed sync.
lssh_write_stamp() {
	local stamp_file="$1"
	local src="$2"
	local branch="$3"
	local head_sha="$4"
	local dirty="$5"
	local synced_at=""
	synced_at="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'unknown')"

	cat >"$stamp_file" <<EOF
{
  "src": "${src}",
  "branch": "${branch}",
  "head_sha": "${head_sha}",
  "dirty": ${dirty},
  "session_id": "${AIDEVOPS_SESSION_ID:-${LSSH_SESSION_ID:-unknown}}",
  "synced_at": "${synced_at}"
}
EOF
	return 0
}

# Print the stamp file contents in human-readable form. Returns 1 if missing.
lssh_print_stamp() {
	local stamp_file="$1"
	if [[ ! -f "$stamp_file" ]]; then
		log_warn "no sync stamp found at ${stamp_file} — destination has not been synced by this helper yet"
		return 1
	fi
	if command -v jq >/dev/null 2>&1; then
		jq -r '"src: \(.src)\nbranch: \(.branch)\nhead_sha: \(.head_sha)\ndirty: \(.dirty)\nsession_id: \(.session_id)\nsynced_at: \(.synced_at)"' "$stamp_file"
	else
		cat "$stamp_file"
	fi
	return 0
}

# Age in seconds of the stamp file's synced_at field, or empty on failure.
lssh_stamp_age_seconds() {
	local stamp_file="$1"
	local synced_at="" synced_epoch="" now_epoch=""
	[[ -f "$stamp_file" ]] || return 1
	if command -v jq >/dev/null 2>&1; then
		synced_at=$(jq -r '.synced_at // empty' "$stamp_file" 2>/dev/null || true)
	else
		synced_at=$(grep -o '"synced_at": *"[^"]*"' "$stamp_file" 2>/dev/null | sed -E 's/.*"([^"]+)"$/\1/' || true)
	fi
	[[ -n "$synced_at" ]] || return 1
	synced_epoch=$(date -u -d "$synced_at" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$synced_at" +%s 2>/dev/null || true)
	[[ -n "$synced_epoch" ]] || return 1
	now_epoch=$(date -u +%s)
	printf '%s\n' "$((now_epoch - synced_epoch))"
	return 0
}

lssh_cmd_status() {
	local dest=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--dest)
			dest="$2"
			shift 2
			;;
		*)
			log_error "status: unknown argument: $1"
			return 1
			;;
		esac
	done
	validate_required_param "--dest" "$dest" || return 1
	local stamp_file
	stamp_file="$(lssh_stamp_path "$dest")"
	lssh_print_stamp "$stamp_file"
	return $?
}

lssh_cmd_sync() {
	local src="" dest="" exclude_from="" force=false
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--src)
			src="$2"
			shift 2
			;;
		--dest)
			dest="$2"
			shift 2
			;;
		--exclude-from)
			exclude_from="$2"
			shift 2
			;;
		--force)
			force=true
			shift
			;;
		*)
			log_error "sync: unknown argument: $1"
			return 1
			;;
		esac
	done
	validate_required_param "--src" "$src" || return 1
	validate_required_param "--dest" "$dest" || return 1

	if [[ ! -d "$src" ]]; then
		log_error "source worktree not found: $src"
		return 1
	fi
	if ! git -C "$src" rev-parse --git-dir >/dev/null 2>&1; then
		log_error "source is not a Git worktree: $src"
		return 1
	fi

	local default_branch head_sha dirty_flag
	default_branch="$(lssh_default_branch "$src")"
	head_sha="$(git -C "$src" rev-parse HEAD 2>/dev/null || printf 'unknown')"
	if [[ -n "$(git -C "$src" status --porcelain 2>/dev/null || true)" ]]; then
		dirty_flag=true
	else
		dirty_flag=false
	fi

	git -C "$src" fetch origin "$default_branch" --quiet 2>/dev/null || log_warn "could not fetch origin/${default_branch}; freshness check uses last known state"

	if [[ "$force" != true ]]; then
		if git -C "$src" rev-parse --verify --quiet "origin/${default_branch}" >/dev/null 2>&1; then
			if ! git -C "$src" merge-base --is-ancestor "origin/${default_branch}" HEAD; then
				log_error "refusing to sync: HEAD does not contain origin/${default_branch}"
				log_error "merge the default branch into this worktree first, or re-run with --force"
				return 1
			fi
		else
			log_warn "origin/${default_branch} not available locally; skipping freshness check (re-fetch or use --force)"
		fi
	fi

	local stamp_file
	stamp_file="$(lssh_stamp_path "$dest")"
	if [[ -f "$stamp_file" ]]; then
		local age
		age="$(lssh_stamp_age_seconds "$stamp_file" || true)"
		if [[ -n "$age" && "$age" -lt "$LSSH_STALE_WARNING_SECONDS" ]]; then
			log_warn "another worktree synced to this destination ${age}s ago — it may still be testing:"
			lssh_print_stamp "$stamp_file" || true
		fi
	fi

	mkdir -p "$dest"

	local rsync_args=(-a --delete --exclude=".git")
	if [[ -n "$exclude_from" ]]; then
		if [[ ! -f "$exclude_from" ]]; then
			log_error "--exclude-from file not found: $exclude_from"
			return 1
		fi
		rsync_args+=(--exclude-from="$exclude_from")
	fi

	local src_slash="${src%/}/"
	local dest_slash="${dest%/}/"
	log_info "syncing ${src_slash} -> ${dest_slash}"
	rsync "${rsync_args[@]}" "$src_slash" "$dest_slash"

	lssh_write_stamp "$stamp_file" "$src" "$default_branch" "$head_sha" "$dirty_flag"
	log_success "synced. stamp written: $stamp_file"
	lssh_print_stamp "$stamp_file" || true
	return 0
}

main() {
	local command="${1:-}"
	[[ $# -gt 0 ]] && shift
	case "$command" in
	sync)
		lssh_cmd_sync "$@"
		return $?
		;;
	status)
		lssh_cmd_status "$@"
		return $?
		;;
	help | --help | -h | "")
		lssh_usage
		return 0
		;;
	*)
		log_error "unknown command: $command"
		lssh_usage
		return 1
		;;
	esac
}

main "$@"
