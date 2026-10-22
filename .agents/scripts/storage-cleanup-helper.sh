#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# storage-cleanup-helper.sh — on-demand and scheduled storage hygiene (GH#35245).
#
# Single entry point for `aidevops cleanup` and the r922 Storage hygiene
# routine. It orchestrates the existing owning cleaners and never deletes
# anything itself, so every cleaner keeps its own safety gates:
#   tmp            system-cleanup.sh (retention window, moves to Trash)
#   worktrees      cleanup-worktrees-async-helper.sh (merged/closed, guarded)
#   artefacts      worktree-artefact-reclaim.sh (ignored build output in idle
#                  linked worktrees; cwd/ownership/recent-edit vetoes, Trash)
#   opencode       opencode-db-maintenance-helper.sh auto (live-DB skips,
#                  isolated DBs, superseded layout-migration backups)
#   observability  observability-helper.sh retention-maintenance (verified
#                  archive partitions)
#
# Usage:
#   storage-cleanup-helper.sh [report]            Sizes and owning cleaners (read-only)
#   storage-cleanup-helper.sh <store> [--apply]   Preview (default) or run one store
#   storage-cleanup-helper.sh all [--apply]       Every store; continues past failures
#   storage-cleanup-helper.sh help
#
# Environment:
#   STORAGE_CLEANUP_SIZE_TIMEOUT     Seconds per sizing call (default 30)
#   STORAGE_CLEANUP_TMP_MAX_SECONDS  tmp apply work budget (default 300)
#   STORAGE_CLEANUP_ARTEFACT_MAX_SECONDS  artefacts apply work budget (default 300)
#   AIDEVOPS_WORKTREE_IDLE_DAYS      artefacts idle threshold in days (default 14)
#   AIDEVOPS_WORKTREE_BASE_DIR       Linked-worktree base (default: worktree-paths.sh)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=./shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"
# shellcheck source=./worktree-paths.sh
source "${SCRIPT_DIR}/worktree-paths.sh"

readonly SC_STORES="tmp worktrees artefacts opencode observability"
readonly SC_SCHEDULE_NAME="storage-hygiene"
readonly SC_APPLY="apply" SC_DRY_RUN="dry-run"
SC_SIZE_TIMEOUT="${STORAGE_CLEANUP_SIZE_TIMEOUT:-30}"
[[ "$SC_SIZE_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || SC_SIZE_TIMEOUT=30
SC_TMP_MAX_SECONDS="${STORAGE_CLEANUP_TMP_MAX_SECONDS:-300}"
[[ "$SC_TMP_MAX_SECONDS" =~ ^[0-9]+$ ]] || SC_TMP_MAX_SECONDS=300
SC_ARTEFACT_MAX_SECONDS="${STORAGE_CLEANUP_ARTEFACT_MAX_SECONDS:-300}"
[[ "$SC_ARTEFACT_MAX_SECONDS" =~ ^[1-9][0-9]*$ ]] || SC_ARTEFACT_MAX_SECONDS=300
# Symlink lock: the link target is the holder PID, so the lock and its owner
# are published in one atomic syscall (no empty-lock window).
SC_LOCK="${AIDEVOPS_LOG_DIR:-${HOME:?}/.aidevops/logs}/storage-cleanup.lock"
readonly SC_LOCK_BUSY=2

# ---------------------------------------------------------------------------
# Store metadata
# ---------------------------------------------------------------------------

_sc_is_store() {
	local store="$1" known=""
	for known in $SC_STORES; do
		[[ "$store" == "$known" ]] && return 0
	done
	return 1
}

# Paths whose combined size is reported for a store, one per line.
_sc_store_paths() {
	local store="$1"
	local workspace="${HOME}/.aidevops/.agent-workspace"
	case "$store" in
	tmp) printf '%s\n' "${AIDEVOPS_TEMP_DIR:-${workspace}/tmp}" ;;
	worktrees) aidevops_worktree_base_dir_configured ;;
	artefacts) ;; # Inside the worktrees total; the preview reports eligible bytes.
	opencode)
		printf '%s\n' "${XDG_DATA_HOME:-${HOME}/.local/share}/opencode" \
			"${workspace}/work/opencode-interactive" \
			"${workspace}/work/opencode-tabby-recovery" \
			"${workspace}/work/repo-layout-migrations"
		;;
	observability) printf '%s\n' "${workspace}/observability" ;;
	*) return 1 ;;
	esac
	return 0
}

_sc_store_cleaner() {
	local store="$1"
	case "$store" in
	tmp) printf '%s\n' "system-cleanup.sh: entries older than ${AIDEVOPS_TMP_RETENTION_DAYS:-7} days move to Trash" ;;
	worktrees) printf '%s\n' "cleanup-worktrees-async-helper.sh: merged/closed worktrees, guarded removal" ;;
	artefacts) printf '%s\n' "worktree-artefact-reclaim.sh: ignored build output in worktrees idle ${AIDEVOPS_WORKTREE_IDLE_DAYS:-14}+ days moves to Trash" ;;
	opencode) printf '%s\n' "opencode-db-maintenance-helper.sh auto: VACUUM, isolated DBs, layout backups" ;;
	observability) printf '%s\n' "observability-helper.sh retention-maintenance: verified archives" ;;
	*) return 1 ;;
	esac
	return 0
}

# ---------------------------------------------------------------------------
# Sizing (bounded; a timeout reports unknown rather than blocking)
# ---------------------------------------------------------------------------

# Prints KiB for one path, 0 when absent; returns 1 when sizing timed out.
# du exits non-zero for individual unreadable entries but still prints a
# usable total, so only a timeout or missing total counts as unknown.
_sc_path_kb() {
	local path="$1" out="" rc=0 kb=""
	[[ -e "$path" ]] || { printf '0\n'; return 0; }
	out=$(timeout_sec "$SC_SIZE_TIMEOUT" du -sk "$path" 2>/dev/null) || rc=$?
	[[ "$rc" -eq 124 || "$rc" -ge 128 ]] && return 1
	kb="${out%%[[:space:]]*}"
	[[ "$kb" =~ ^[0-9]+$ ]] || return 1
	printf '%s\n' "$kb"
	return 0
}

# Prints total KiB for a store; returns 1 when any part could not be sized.
_sc_store_kb() {
	local store="$1" path="" kb="" total=0
	while IFS= read -r path; do
		[[ -n "$path" ]] || continue
		kb=$(_sc_path_kb "$path") || return 1
		[[ "$kb" =~ ^[0-9]+$ ]] || return 1
		total=$((total + kb))
	done < <(_sc_store_paths "$store")
	printf '%s\n' "$total"
	return 0
}

_sc_human_kb() {
	local kb="$1"
	awk -v kb="$kb" 'BEGIN {
		split("K M G T", unit, " "); size = kb; i = 1
		while (size >= 1024 && i < 4) { size /= 1024; i++ }
		printf (i == 1 ? "%d%s\n" : "%.1f%s\n"), size, unit[i]
	}'
	return 0
}

_sc_worktree_count() {
	local base="" count=0 entry=""
	base=$(aidevops_worktree_base_dir_configured)
	[[ -d "$base" ]] || { printf '0\n'; return 0; }
	for entry in "$base"/*; do
		[[ -d "$entry" ]] && count=$((count + 1))
	done
	printf '%s\n' "$count"
	return 0
}

# Reports whether the r922 platform scheduler is installed.
_sc_schedule_state() {
	if command -v launchctl >/dev/null 2>&1; then
		launchctl list "sh.aidevops.${SC_SCHEDULE_NAME}" >/dev/null 2>&1 && { printf 'installed (launchd)\n'; return 0; }
	fi
	if command -v systemctl >/dev/null 2>&1; then
		systemctl --user is-enabled "aidevops-${SC_SCHEDULE_NAME}.timer" >/dev/null 2>&1 && { printf 'installed (systemd)\n'; return 0; }
	fi
	if command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -F "aidevops: ${SC_SCHEDULE_NAME}" >/dev/null; then
		printf 'installed (cron)\n'
		return 0
	fi
	printf 'not installed (run: aidevops update)\n'
	return 0
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_report() {
	local store="" kb="" size="" note="" timed_out=0
	printf 'aidevops storage report (read-only; nothing is deleted)\n\n'
	printf '%-14s %-9s %s\n' "STORE" "SIZE" "OWNING CLEANER"
	for store in $SC_STORES; do
		if [[ "$store" == "artefacts" ]]; then
			# Counted inside worktrees; eligibility needs the bounded preview.
			size="(in wt)"
		elif kb=$(_sc_store_kb "$store"); then
			size=$(_sc_human_kb "$kb")
		else
			size="?"
			timed_out=1
		fi
		note=""
		[[ "$store" == "worktrees" ]] && note=" ($(_sc_worktree_count) worktrees)"
		printf '%-14s %-9s %s%s\n' "$store" "$size" "$(_sc_store_cleaner "$store")" "$note"
	done
	if [[ "$timed_out" -eq 1 ]]; then
		printf '\n? = sizing stopped after %ss; set STORAGE_CLEANUP_SIZE_TIMEOUT=300 for a full total.\n' "$SC_SIZE_TIMEOUT"
	fi
	printf '\nPreview one store:  aidevops cleanup <%s>\n' "${SC_STORES// /|}"
	printf 'Reclaim space:      aidevops cleanup all --apply\n'
	printf 'Daily routine r922: %s\n' "$(_sc_schedule_state)"
	return 0
}

# Summarise the tmp dry run: the first few eligible entries plus the totals
# line, so a large backlog does not flood an `all` preview.
_sc_preview_tmp() {
	local out="" rc=0 total=0 shown=5
	out=$(bash "${SCRIPT_DIR}/system-cleanup.sh" --dry-run --max-seconds 60) || rc=$?
	total=$(grep -c '^\[dry-run\]' <<<"$out") || total=0
	# awk reads all input (no early exit), so pipefail never sees SIGPIPE.
	awk -v n="$shown" '/^\[dry-run\]/ { if (++c <= n) print }' <<<"$out"
	if [[ "$total" -gt "$shown" ]]; then
		printf '  ... %s more (full list: system-cleanup.sh --dry-run)\n' "$((total - shown))"
	fi
	printf '%s\n' "$out" | grep -v '^\[dry-run\]'
	return "$rc"
}

# Summarise the artefact dry run per worktree (not per directory) so a large
# monorepo does not flood an `all` preview.
_sc_preview_artefacts() {
	local out="" rc=0
	out=$(bash "${SCRIPT_DIR}/worktree-artefact-reclaim.sh" --max-seconds 60) || rc=$?
	printf '%s\n' "$out" | grep -v "dry-run path=" || true
	printf 'Apply moves only ignored node_modules/.next/.turbo/dist/build, Cargo target/ and .hermit caches to Trash.\n'
	return "$rc"
}

# Opt-in OpenCode session retention (storage.opencode_session_retention_days).
_sc_preview_opencode_retention() {
	local archive="${SCRIPT_DIR}/opencode-db-archive.sh" days="" rc=0
	days=$(bash "$archive" retention-days) || days=0
	[[ "$days" =~ ^[0-9]+$ ]] || days=0
	if [[ "$days" -eq 0 ]]; then
		printf 'Session retention: keep all (storage.opencode_session_retention_days=0)\n'
		return 0
	fi
	printf 'Session retention: delete sessions older than %s days (storage.opencode_session_retention_days=%s; permanent). Dry run:\n' "$days" "$days"
	bash "$archive" prune-all --older-than-days "$days" --dry-run || rc=$?
	[[ "$rc" -eq 2 ]] && rc=0
	return "$rc"
}

_sc_dry_run_store() {
	local store="$1" rc=0
	case "$store" in
	tmp) _sc_preview_tmp || rc=$? ;;
	worktrees)
		printf 'Linked worktrees: %s under %s\n' "$(_sc_worktree_count)" "$(aidevops_worktree_base_dir_configured)"
		printf 'Apply removes only worktrees whose branches are merged or closed; dirty work is archived first.\n'
		;;
	artefacts) _sc_preview_artefacts || rc=$? ;;
	opencode)
		printf 'Superseded/expired layout-migration backups (dry run):\n'
		bash "${SCRIPT_DIR}/repo-layout-migrate-helper.sh" prune || rc=$?
		_sc_preview_opencode_retention || rc=$?
		printf 'Apply also checkpoints/optimizes each idle OpenCode DB (throttled to weekly).\n'
		;;
	observability)
		bash "${SCRIPT_DIR}/observability-helper.sh" retention-maintenance --dry-run \
			--max-partitions 20 --max-duration-seconds 120 || rc=$?
		;;
	*) return 1 ;;
	esac
	return "$rc"
}

_sc_last_worktree_outcome() {
	local log="${AIDEVOPS_LOG_DIR:-${HOME}/.aidevops/logs}/cleanup_worktrees.log" line=""
	[[ -f "$log" ]] || return 0
	line=$(grep -F 'outcome=' "$log" 2>/dev/null | tail -n 1) || line=""
	[[ -n "$line" ]] && printf '%s\n' "$line"
	return 0
}

_sc_apply_store() {
	local store="$1" rc=0
	case "$store" in
	tmp) bash "${SCRIPT_DIR}/system-cleanup.sh" --force --max-seconds "$SC_TMP_MAX_SECONDS" || rc=$? ;;
	worktrees)
		CLEANUP_WORKTREES_ASYNC_CADENCE_MIN=0 bash "${SCRIPT_DIR}/cleanup-worktrees-async-helper.sh" || rc=$?
		_sc_last_worktree_outcome
		;;
	artefacts) bash "${SCRIPT_DIR}/worktree-artefact-reclaim.sh" --force --max-seconds "$SC_ARTEFACT_MAX_SECONDS" || rc=$? ;;
	opencode) bash "${SCRIPT_DIR}/opencode-db-maintenance-helper.sh" auto || rc=$? ;;
	observability)
		bash "${SCRIPT_DIR}/observability-helper.sh" retention-maintenance --apply \
			--max-partitions 20 --max-duration-seconds 120 || rc=$?
		;;
	*) return 1 ;;
	esac
	return "$rc"
}

_sc_lock_release() {
	# Remove the lock only while this process still owns it.
	[[ "$(readlink "$SC_LOCK" 2>/dev/null)" == "$$" ]] && rm -f "$SC_LOCK"
	return 0
}

# Returns 0 when acquired, SC_LOCK_BUSY when another live run holds it, 1 on
# an operational lock error (the caller must not clean without a lock).
_sc_lock_acquire() {
	local holder="" moved="" stale="${SC_LOCK}.stale.$$"
	if ! mkdir -p "${SC_LOCK%/*}" 2>/dev/null; then
		print_error "Cannot create lock directory ${SC_LOCK%/*}"
		return 1
	fi
	if ! ln -s "$$" "$SC_LOCK" 2>/dev/null; then
		holder=$(readlink "$SC_LOCK" 2>/dev/null) || holder=""
		if [[ ! -L "$SC_LOCK" ]] && [[ -e "$SC_LOCK" ]]; then
			print_error "Lock path is not a symlink: ${SC_LOCK}"
			return 1
		fi
		if [[ "$holder" =~ ^[0-9]+$ ]] && ps -p "$holder" >/dev/null 2>&1; then
			print_warning "Storage cleanup already running (PID ${holder}); skipping"
			return "$SC_LOCK_BUSY"
		fi
		# Stale lock: rename (atomic) and confirm we moved the dead holder's
		# link, not a lock a concurrent contender has just re-created.
		if mv "$SC_LOCK" "$stale" 2>/dev/null; then
			moved=$(readlink "$stale" 2>/dev/null) || moved=""
			if [[ "$moved" != "$holder" ]]; then
				ln -s "$moved" "$SC_LOCK" 2>/dev/null || true
				rm -f "$stale"
				print_warning "Storage cleanup lock changed hands; skipping"
				return "$SC_LOCK_BUSY"
			fi
			rm -f "$stale"
		fi
		if ! ln -s "$$" "$SC_LOCK" 2>/dev/null; then
			print_warning "Storage cleanup lock taken by another run; skipping"
			return "$SC_LOCK_BUSY"
		fi
	fi
	trap '_sc_lock_release' EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM
	return 0
}

cmd_store() {
	local store="$1" mode="$2" rc=0
	if [[ "$mode" == "$SC_APPLY" ]]; then
		print_info "Cleaning ${store}: $(_sc_store_cleaner "$store")"
		_sc_apply_store "$store" || rc=$?
	else
		print_info "Preview ${store} (dry run; add --apply to reclaim): $(_sc_store_cleaner "$store")"
		_sc_dry_run_store "$store" || rc=$?
	fi
	[[ "$rc" -eq 0 ]] || print_warning "${store}: cleaner exited ${rc}"
	return "$rc"
}

cmd_all() {
	local mode="$1" store="" failed=""
	for store in $SC_STORES; do
		cmd_store "$store" "$mode" || failed="${failed}${failed:+ }${store}"
		printf '\n'
	done
	if [[ -n "$failed" ]]; then
		print_error "Storage cleanup incomplete; failed stores: ${failed}"
		return 1
	fi
	if [[ "$mode" == "$SC_APPLY" ]]; then
		print_success "Storage cleanup complete. Run 'aidevops cleanup' to see current sizes."
	fi
	return 0
}

cmd_help() {
	cat <<EOF
Usage: aidevops cleanup [report|all|<store>] [--apply]

Storage cleanup (dry-run unless --apply):
  report                Sizes of aidevops-owned stores and their cleaners (default)
  all [--apply]         Preview or clean every store
  <store> [--apply]     One store: ${SC_STORES// /, }

Every store is cleaned by its existing owner with that owner's safety gates;
this command never deletes files itself. The daily r922 Storage hygiene routine
runs 'all --apply' automatically once setup.sh/aidevops update installs it.
EOF
	return 0
}

main() {
	local subcommand="${1:-report}" mode="$SC_DRY_RUN" arg=""
	[[ $# -gt 0 ]] && shift
	for arg in "$@"; do
		case "$arg" in
		--apply) mode="$SC_APPLY" ;;
		--dry-run) mode="$SC_DRY_RUN" ;;
		*) print_error "Unknown option: ${arg}"; return 1 ;;
		esac
	done
	case "$subcommand" in
	report | status) cmd_report ;;
	help | --help | -h) cmd_help ;;
	*)
		if [[ "$subcommand" != "all" ]] && ! _sc_is_store "$subcommand"; then
			print_error "Unknown cleanup target: ${subcommand}"
			cmd_help
			return 1
		fi
		if [[ "$mode" == "$SC_APPLY" ]]; then
			local lock_rc=0
			_sc_lock_acquire || lock_rc=$?
			# A concurrent run is a normal skip; any other lock error fails.
			[[ "$lock_rc" -eq "$SC_LOCK_BUSY" ]] && return 0
			[[ "$lock_rc" -eq 0 ]] || return 1
		fi
		if [[ "$subcommand" == "all" ]]; then
			cmd_all "$mode"
		else
			cmd_store "$subcommand" "$mode"
		fi
		;;
	esac
	return $?
}

main "$@"
