#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# cleanup-worktrees-async-helper.sh — Async background worktree cleanup runner (GH#20554).
#
# Designed to be invoked by _preflight_launch_async_cleanup from
# _preflight_cleanup_and_ledger. Linux systemd hosts use a transient user
# service outside the parent pulse cgroup; other hosts retain a nohup fallback.
#
# Lifecycle:
#   1. Acquire a mkdir-based single-runner lock (~/.aidevops/logs/cleanup_worktrees.lock).
#   2. Check cadence gate: skip if last successful run < N minutes ago.
#   3. Prune metadata for vanished worktrees and reclaim retained branch-cleanup
#      transports in every managed repo (API-free), then call cleanup_worktrees.
#   4. Update ~/.aidevops/logs/cleanup_worktrees.last-run on success.
#   5. Release lock on EXIT/INT/TERM (trap).
#
# Usage (from pulse-dispatch-preflight-lib.sh):
#   _preflight_launch_async_cleanup \
#     "${SCRIPT_DIR}/cleanup-worktrees-async-helper.sh" \
#     "${HOME}/.aidevops/logs/cleanup_worktrees.log" "worktrees"
#
# DO NOT call cleanup_worktrees inline in pulse-dispatch-engine.sh after
# this helper is deployed — use this wrapper instead.
#
# Environment:
#   CLEANUP_WORKTREES_ASYNC_CADENCE_MIN — min minutes between runs (default 10)
#   CLEANUP_WORKTREES_PRESSURE_BUDGET — cleanup_worktrees seconds under capacity pressure (default 900; routine 120)
#   AIDEVOPS_WORKTREE_CLEANUP_FREE_PERCENT — soft free-space percentage (default 15)
#   AIDEVOPS_WORKTREE_CLEANUP_FREE_KB — soft free-space floor (default 4x creation floor)
#   DIRTY_WORKTREE_BACKUP_RETENTION_DAYS — stale dirty-backup retention (default 30)
#   AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_ENABLED — automatic terminal-archive maintenance (default 1)
#   AIDEVOPS_WORKTREE_ARCHIVE_RETENTION_MODE — off|dry-run|apply (default dry-run)
#   AIDEVOPS_WORKTREE_ARCHIVE_RETENTION_DAYS — compact archive age (default 14)
#   AIDEVOPS_WORKTREE_ARCHIVE_MAX_TOTAL_SIZE — eligible archive cap (default 20G)
#   AIDEVOPS_WORKTREE_PRODUCER_ARCHIVE_TTL_DAYS — producer archive age from capture, once its source is gone (default 30)
#   AIDEVOPS_LOG_DIR — explicit log directory override (required if HOME unset)
#
# Observability (for pulse-diagnose-helper.sh):
#   ~/.aidevops/logs/cleanup_worktrees.log      — progress log
#   ~/.aidevops/logs/cleanup_worktrees.last-run — epoch of last successful run
#   ~/.aidevops/logs/cleanup_worktrees.lock/    — lock dir (present = running)
#   ~/.aidevops/logs/cleanup_worktrees.lock/pid — PID of holder

set -euo pipefail

# ============================================================
# PATHS
# ============================================================

_SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$_SCRIPT_PATH")" && pwd)"
unset _SCRIPT_PATH

if [[ -z "${AIDEVOPS_LOG_DIR:-}" && -z "${HOME:-}" ]]; then
	printf '%s\n' "[cleanup-worktrees-async] ERROR: HOME is unset and AIDEVOPS_LOG_DIR is not configured" >&2
	exit 1
fi

readonly LOG_DIR="${AIDEVOPS_LOG_DIR:-${HOME:-}/.aidevops/logs}"
readonly LOGFILE="${LOG_DIR}/cleanup_worktrees.log"
readonly LOCK_DIR="${LOG_DIR}/cleanup_worktrees.lock"
readonly PID_FILE="${LOCK_DIR}/pid"
readonly LAST_RUN_FILE="${LOG_DIR}/cleanup_worktrees.last-run"

# Minimum minutes between successful runs
CLEANUP_WORKTREES_ASYNC_CADENCE_MIN="${CLEANUP_WORKTREES_ASYNC_CADENCE_MIN:-10}"
# Validate: strip non-digits, fall back to default on empty
CLEANUP_WORKTREES_ASYNC_CADENCE_MIN="${CLEANUP_WORKTREES_ASYNC_CADENCE_MIN//[!0-9]/}"
[[ -n "$CLEANUP_WORKTREES_ASYNC_CADENCE_MIN" ]] || CLEANUP_WORKTREES_ASYNC_CADENCE_MIN=10

# GH#37330: cleanup_worktrees splits its budget between the observation-era and
# registry passes. One archive-first retirement takes about 50 s, so the routine
# 120 s retires roughly one tree per run, too slow to drain a capacity backlog
# while dispatch stays fail-closed. Under pressure this detached helper may
# spend longer; budgets are checked between operations, never mid-retirement.
readonly _CLEANUP_WORKTREES_ROUTINE_BUDGET=120
readonly _CLEANUP_WORKTREES_PRESSURE_BUDGET_DEFAULT=900
CLEANUP_WORKTREES_PRESSURE_BUDGET="${CLEANUP_WORKTREES_PRESSURE_BUDGET:-$_CLEANUP_WORKTREES_PRESSURE_BUDGET_DEFAULT}"
[[ "$CLEANUP_WORKTREES_PRESSURE_BUDGET" =~ ^[1-9][0-9]{0,4}$ ]] ||
	CLEANUP_WORKTREES_PRESSURE_BUDGET="$_CLEANUP_WORKTREES_PRESSURE_BUDGET_DEFAULT"

# Keep a single previous generation so routine cleanup diagnostics cannot grow
# without bound. Operators may lower this cap for constrained hosts.
AIDEVOPS_CLEANUP_LOG_MAX_MB="${AIDEVOPS_CLEANUP_LOG_MAX_MB:-20}"
AIDEVOPS_CLEANUP_LOG_MAX_MB="${AIDEVOPS_CLEANUP_LOG_MAX_MB//[!0-9]/}"
[[ "$AIDEVOPS_CLEANUP_LOG_MAX_MB" =~ ^[1-9][0-9]{0,3}$ ]] || AIDEVOPS_CLEANUP_LOG_MAX_MB=20

mkdir -p "$LOG_DIR"

# ============================================================
# SOURCE DEPENDENCIES
# ============================================================

# shared-constants.sh pulls in shared-worktree-registry.sh (is_worktree_owned_by_others),
# shared-gh-wrappers.sh (gh_issue_comment), and other shared utilities.
# shellcheck source=shared-constants.sh
if [[ -f "${SCRIPT_DIR}/shared-constants.sh" ]]; then
	source "${SCRIPT_DIR}/shared-constants.sh"
else
	echo "[cleanup-worktrees-async] ERROR: shared-constants.sh not found at ${SCRIPT_DIR}" >>"$LOGFILE"
	exit 1
fi

# pulse-cleanup.sh defines cleanup_worktrees and all its private helpers.
# It has an idempotent guard (_PULSE_CLEANUP_LOADED) and no unconditional
# side effects at source time — safe to source standalone.
# shellcheck source=pulse-cleanup.sh
if [[ -f "${SCRIPT_DIR}/pulse-cleanup.sh" ]]; then
	source "${SCRIPT_DIR}/pulse-cleanup.sh"
else
	echo "[cleanup-worktrees-async] ERROR: pulse-cleanup.sh not found at ${SCRIPT_DIR}" >>"$LOGFILE"
	exit 1
fi
if [[ -f "${SCRIPT_DIR}/audit-worktree-removal-helper.sh" ]]; then
	# shellcheck source=audit-worktree-removal-helper.sh
	source "${SCRIPT_DIR}/audit-worktree-removal-helper.sh"
fi

# ============================================================
# LOCK MANAGEMENT (mkdir-based — POSIX atomic, macOS-safe)
# ============================================================

# shellcheck source=cleanup-worktrees-lock.sh
source "${SCRIPT_DIR}/cleanup-worktrees-lock.sh"
if [[ -f "${SCRIPT_DIR}/disk-capacity-lib.sh" ]]; then
	# shellcheck source=disk-capacity-lib.sh
	source "${SCRIPT_DIR}/disk-capacity-lib.sh"
fi

# ============================================================
# CADENCE GATE
# ============================================================

# Returns 0 (proceed) if enough time has elapsed since the last successful run.
# Returns 1 (skip) if we are within the cadence window.
_cadence_ok() {
	if [[ ! -f "$LAST_RUN_FILE" ]]; then
		return 0 # First run — always proceed
	fi

	local last_run now elapsed cadence_secs
	last_run=$(cat "$LAST_RUN_FILE" 2>/dev/null || echo "0")
	if ! [[ "$last_run" =~ ^[0-9]+$ ]]; then
		return 0 # Corrupted state file — proceed
	fi

	now=$(date +%s)
	elapsed=$((now - last_run))
	cadence_secs=$((CLEANUP_WORKTREES_ASYNC_CADENCE_MIN * 60))

	if [[ "$elapsed" -lt "$cadence_secs" ]]; then
		echo "[cleanup-worktrees-async] Cadence gate: last run ${elapsed}s ago (threshold ${cadence_secs}s). Skipping." >>"$LOGFILE"
		return 1
	fi

	return 0
}

_update_last_run() {
	date +%s >"$LAST_RUN_FILE" 2>/dev/null || true
	return 0
}

_rotate_log_if_oversize() {
	local log_size=0
	local max_size=$((AIDEVOPS_CLEANUP_LOG_MAX_MB * 1024 * 1024))
	local rotated_log="${LOGFILE}.1"

	[[ -f "$LOGFILE" ]] || return 0
	log_size=$(wc -c <"$LOGFILE" | tr -d '[:space:]') || return 0
	[[ "$log_size" =~ ^[0-9]+$ && "$log_size" -gt "$max_size" ]] || return 0
	rm -f "$rotated_log" 2>/dev/null || return 0
	mv "$LOGFILE" "$rotated_log" 2>/dev/null || return 0
	printf '[cleanup-worktrees-async] rotated log bytes=%s cap_mb=%s\n' \
		"$log_size" "$AIDEVOPS_CLEANUP_LOG_MAX_MB" >>"$LOGFILE"
	return 0
}

_skip_reason_summary() {
	local first_line="$1"
	local owned_skip=0
	local parent_runtime_active=0

	[[ "$first_line" =~ ^[0-9]+$ ]] || first_line=0
	read -r owned_skip parent_runtime_active < <(
		awk -v first_line="$first_line" '
			NR > first_line && /worktree-skipped:.*— owned-skip —/ { owned_skip++ }
			NR > first_line && /worktree-skipped:.*— parent-runtime-active —/ { parent_runtime_active++ }
			END { printf "%d %d\\n", owned_skip, parent_runtime_active }
		' "$LOGFILE" 2>/dev/null
	)
	[[ "$owned_skip" =~ ^[0-9]+$ ]] || owned_skip=0
	[[ "$parent_runtime_active" =~ ^[0-9]+$ ]] || parent_runtime_active=0
	if [[ "$owned_skip" -eq 0 && "$parent_runtime_active" -eq 0 ]]; then
		printf '%s\n' "none"
	else
		printf 'owned-skip:%s,parent-runtime-active:%s\n' "$owned_skip" "$parent_runtime_active"
	fi
	return 0
}

_reconcile_worktree_registry() {
	if ! declare -F prune_worktree_registry >/dev/null 2>&1; then
		echo "[cleanup-worktrees-async] registry prune unavailable; skipping reconciliation" >>"$LOGFILE"
		return 0
	fi
	if ! prune_worktree_registry >>"$LOGFILE" 2>&1; then
		echo "[cleanup-worktrees-async] registry reconciliation failed closed; continuing guarded cleanup" >>"$LOGFILE"
		return 0
	fi
	return 0
}

_prune_dirty_worktree_backups() {
	local helper_path="${SCRIPT_DIR}/dirty-worktree-backup-helper.sh"
	local retention_days="${DIRTY_WORKTREE_BACKUP_RETENTION_DAYS:-30}"

	if [[ ! -x "$helper_path" ]]; then
		echo "[cleanup-worktrees-async] dirty backup helper unavailable; skipping backup prune" >>"$LOGFILE"
		return 0
	fi

	"$helper_path" prune --force --retention-days "$retention_days" >>"$LOGFILE" 2>&1 || {
		echo "[cleanup-worktrees-async] dirty backup prune failed; continuing" >>"$LOGFILE"
		return 0
	}
	return 0
}

_maintain_worktree_recovery() {
	local helper_path="${SCRIPT_DIR}/worktree-recovery-maintenance-helper.sh"
	local result=""
	local result_status=0

	if [[ ! -x "$helper_path" ]]; then
		echo "[cleanup-worktrees-async] recovery maintenance helper unavailable; skipping" >>"$LOGFILE"
		return 0
	fi
	if result=$("$helper_path" compact 2>>"$LOGFILE"); then
		result_status=0
	else
		result_status=$?
	fi
	printf '%s\trc=%s\t%s\n' "[cleanup-worktrees-async] recovery-maintenance" "$result_status" "$result" >>"$LOGFILE"
	return 0
}

# Retention is separately opted into: cleanup consent alone does not authorize
# destroying the last recovery copy. Share the async lock and bounded runner.
_maintain_compact_archives() {
	local mode="${AIDEVOPS_WORKTREE_ARCHIVE_RETENTION_MODE:-}"
	local days="${AIDEVOPS_WORKTREE_ARCHIVE_RETENTION_DAYS:-14}"
	local maximum="${AIDEVOPS_WORKTREE_ARCHIVE_MAX_TOTAL_SIZE:-20G}"
	# Producer archives may be the only copy: longer than the compact default.
	local producer_ttl="${AIDEVOPS_WORKTREE_PRODUCER_ARCHIVE_TTL_DAYS:-30}"
	# prune stops itself inside this budget; the outer timeout is only a
	# backstop. Each verification may import a base graph (GH#36468).
	local budget="${AIDEVOPS_WORKTREE_ARCHIVE_PRUNE_BUDGET:-540}"
	local helper="${SCRIPT_DIR}/worktree-archive-helper.sh"
	local rc=0

	[[ "$budget" =~ ^[1-9][0-9]*$ ]] || budget=540
	# Dead verification scratch is derived data, not a recovery copy: reclaim
	# it in every retention mode, including off.
	if [[ -f "$helper" ]] && declare -F timeout_sec >/dev/null 2>&1; then
		timeout_sec 60 bash "$helper" sweep-scratch >>"$LOGFILE" 2>&1 ||
			echo "[cleanup-worktrees-async] verify-scratch sweep failed; retrying next pass" >>"$LOGFILE"
	fi
	if [[ -z "$mode" ]] && declare -F config_get >/dev/null 2>&1; then
		mode=$(config_get "storage.worktree_archive_retention_mode" "dry-run")
	fi
	mode="${mode:-dry-run}"
	[[ "$mode" != "off" ]] || return 0
	if [[ "$mode" != "dry-run" && "$mode" != "apply" ]] ||
		[[ ! "$days" =~ ^[1-9][0-9]*$ || ! "$producer_ttl" =~ ^[1-9][0-9]*$ ||
			! "$maximum" =~ ^[1-9][0-9]*([KMGTP])?$ ]]; then
		echo "[cleanup-worktrees-async] compact-retention invalid policy; preserving archives" >>"$LOGFILE"
		return 0
	fi
	if [[ ! -f "$helper" ]] || ! declare -F timeout_sec >/dev/null 2>&1; then
		echo "[cleanup-worktrees-async] compact-retention helper or bounded runner unavailable; skipping" >>"$LOGFILE"
		return 0
	fi
	timeout_sec $((budget + 60)) bash "$helper" prune --older-than "${days}d" \
		--max-total-size "$maximum" "--${mode}" --budget-seconds "$budget" \
		--producer-ttl-days "$producer_ttl" >>"$LOGFILE" 2>&1 || rc=$?
	printf '[cleanup-worktrees-async] compact-retention mode=%s rc=%s\n' "$mode" "$rc" >>"$LOGFILE"
	return 0
}

# Print the current repo plus every repos.json repository path, once each.
# Arg: "true" = bounded git lookup, skip local_only repos (capacity); "bounded" = bounded lookup, include local_only.
_missing_metadata_repo_paths() {
	local capacity_only="${1:-false}"
	local repos_json="${HOME:+${HOME}/.config/aidevops/repos.json}"
	local repo_path=""
	local seen=$'\n'

	{
		if [[ "$capacity_only" == true || "$capacity_only" == bounded ]]; then
			timeout_sec 5 git rev-parse --show-toplevel 2>/dev/null || true
		else
			git rev-parse --show-toplevel 2>/dev/null || true
		fi
		if [[ -n "$repos_json" && -f "$repos_json" ]] && command -v jq >/dev/null 2>&1; then
			jq -r '.initialized_repos[]? | .path // empty' "$repos_json" 2>/dev/null || true
		fi
	} | while IFS= read -r repo_path; do
		[[ -n "$repo_path" && "$seen" != *$'\n'"${repo_path}"$'\n'* ]] || continue
		seen="${seen}${repo_path}"$'\n'
		if [[ "$capacity_only" == true && -f "$repos_json" ]] &&
			jq -e --arg path "$repo_path" '.initialized_repos[]? | select(.path == $path and .local_only == true)' "$repos_json" >/dev/null 2>&1; then
			continue
		fi
		printf '%s\n' "$repo_path"
	done
	return 0
}

# Bound the whole repository sweep, not just each individual repository.
_prune_turbo_caches() {
	local helper="${SCRIPT_DIR}/worktree-artefact-reclaim.sh"
	local repo="" deadline=$((SECONDS + 60)) remaining=0 rc=0
	[[ -f "$helper" ]] && declare -F timeout_sec >/dev/null 2>&1 || return 0
	while IFS= read -r repo; do
		remaining=$((deadline - SECONDS))
		[[ "$remaining" -gt 0 ]] || break
		rc=0
		timeout_sec "$remaining" bash "$helper" --turbo-cache "$repo" >>"$LOGFILE" 2>&1 || rc=$?
		[[ "$rc" -eq 0 ]] || printf '[cleanup-worktrees-async] turbo-cache-prune failed rc=%s\n' "$rc" >>"$LOGFILE"
	done < <(_missing_metadata_repo_paths bounded)
	return 0
}

# Print the first prunable entry whose directory is absent. Native
# `git worktree prune` is repo-wide, so return 1 without output when any absent
# entry's parent directory is also absent (for example an unmounted volume):
# that repo is deferred rather than risking metadata for recoverable work.
_missing_worktree_prune_target() {
	local repo_context="$1"
	local field=""
	local wt_path=""
	local parent=""
	local target=""

	while IFS= read -r -d '' field; do
		case "$field" in
		worktree\ *)
			wt_path="${field#worktree }"
			;;
		prunable | prunable\ *)
			[[ -n "$wt_path" && ! -e "$wt_path" ]] || continue
			parent="${wt_path%/*}"
			[[ -d "${parent:-/}" ]] || return 1
			[[ -n "$target" ]] || target="$wt_path"
			;;
		"")
			wt_path=""
			;;
		esac
	done < <(git -C "$repo_context" worktree list --porcelain -z 2>/dev/null || true)

	[[ -z "$target" ]] || printf '%s\n' "$target"
	return 0
}

# Reconcile Git metadata for linked worktrees that vanished outside aidevops
# (for example a reboot wiping /tmp) in every managed repository (GH#32913).
# The pass is local and API-free, so it runs every cycle independently of the
# GitHub-dependent cleanup outcome. The audited primitive only prunes an absent
# target and verifies its metadata disappeared; locked entries are preserved.
_prune_missing_worktree_metadata_all_repos() {
	local repo_context=""
	local target=""
	local pruned=0
	local failed=0
	local deferred=0

	declare -F prune_missing_worktree_metadata >/dev/null 2>&1 || return 0
	command -v git >/dev/null 2>&1 || return 0

	while IFS= read -r repo_context; do
		[[ -d "$repo_context" ]] || continue
		if ! target=$(_missing_worktree_prune_target "$repo_context"); then
			deferred=$((deferred + 1))
			echo "[cleanup-worktrees-async] missing worktree metadata prune deferred repo=${repo_context}: an absent entry's parent directory is unavailable" >>"$LOGFILE"
			continue
		fi
		[[ -n "$target" ]] || continue
		if prune_missing_worktree_metadata "$repo_context" "$target"; then
			pruned=$((pruned + 1))
			echo "[cleanup-worktrees-async] pruned missing worktree metadata repo=${repo_context}" >>"$LOGFILE"
		else
			failed=$((failed + 1))
			echo "[cleanup-worktrees-async] missing worktree metadata prune failed closed repo=${repo_context}; continuing" >>"$LOGFILE"
		fi
	done < <(_missing_metadata_repo_paths)

	echo "[cleanup-worktrees-async] missing-metadata-prune repos_pruned=${pruned} failed=${failed} deferred=${deferred}" >>"$LOGFILE"
	return 0
}

# Reclaim retained branch-cleanup deletion transports in every managed
# repository (GH#35490). Local and API-free like the metadata pass above; the
# audited primitive keeps live, locked, active-CWD or content-bearing trees.
_reclaim_branch_cleanup_transports_all_repos() {
	local repo_context=""
	local reclaimed=0
	local total=0

	declare -F reclaim_branch_cleanup_transports >/dev/null 2>&1 || return 0
	command -v git >/dev/null 2>&1 || return 0

	while IFS= read -r repo_context; do
		[[ -d "$repo_context" ]] || continue
		reclaimed=$(reclaim_branch_cleanup_transports "$repo_context" "cleanup-worktrees-async-helper.sh") || reclaimed=0
		[[ "$reclaimed" =~ ^[0-9]+$ ]] || reclaimed=0
		[[ "$reclaimed" -eq 0 ]] || echo "[cleanup-worktrees-async] reclaimed ${reclaimed} branch-cleanup transport(s) repo=${repo_context}" >>"$LOGFILE"
		total=$((total + reclaimed))
	done < <(_missing_metadata_repo_paths)

	echo "[cleanup-worktrees-async] branch-cleanup-transport-reclaim reclaimed=${total}" >>"$LOGFILE"
	return 0
}

# ============================================================
# MAIN
# ============================================================

_reconcile_lifecycle_receipts() {
	local helper="${SCRIPT_DIR}/worktree_lifecycle_status.py"
	local rc=0
	if [[ ! -f "$helper" ]] || ! declare -F timeout_sec >/dev/null 2>&1; then
		echo "[cleanup-worktrees-async] lifecycle reconciliation unavailable; preserving receipts" >>"$LOGFILE"
		return 0
	fi
	# Metadata-only: never delete sources or recovery artifacts. The existing
	# async lock and bounded runner also apply when invoked independently of Pulse.
	timeout_sec 90 python3 "$helper" reconcile --max-attempts 5 >>"$LOGFILE" 2>&1 || rc=$?
	printf '[cleanup-worktrees-async] lifecycle-reconcile rc=%s\n' "$rc" >>"$LOGFILE"
	return 0
}

# Print "<cap> <cleanup-threshold>"; the shared lib owns the defaults.
_worktree_cap_and_threshold() {
	local cap="${AIDEVOPS_MAX_WORKTREES:-1000}"
	local threshold=""
	if declare -F aidevops_worktree_count_cap >/dev/null 2>&1; then
		cap=$(aidevops_worktree_count_cap)
		threshold=$(aidevops_worktree_cleanup_threshold "$cap")
	else
		[[ "$cap" =~ ^[1-9][0-9]*$ ]] || cap=1000
		threshold=$(((cap * 80 + 99) / 100))
	fi
	printf '%s %s\n' "$cap" "$threshold"
	return 0
}

_worktree_pressure_present() {
	local max_count="" threshold=""
	local repo_context="" listing="" count=0 line=""
	WORKTREE_PRESSURE_REASON="capacity-pressure"
	# HOME may be unset when AIDEVOPS_LOG_DIR is explicit; skip that probe then.
	local worktree_base="${AIDEVOPS_WORKTREE_BASE_DIR:-${HOME:+${HOME}/Git/_worktrees}}"
	read -r max_count threshold < <(_worktree_cap_and_threshold)
	if [[ -n "$worktree_base" ]] && declare -F aidevops_worktree_capacity_check >/dev/null 2>&1; then
		aidevops_worktree_capacity_check "$worktree_base" || return 0
		if declare -F aidevops_worktree_cleanup_headroom_low >/dev/null 2>&1 && aidevops_worktree_cleanup_headroom_low; then
			WORKTREE_PRESSURE_REASON="disk-headroom"
			return 0
		fi
	fi
	while IFS= read -r repo_context; do
		listing=$(git -C "$repo_context" worktree list --porcelain 2>/dev/null) || continue
		count=0
		while IFS= read -r line; do
			case "$line" in
			"worktree "*) count=$((count + 1)) ;;
			prunable | "prunable "*) count=$((count - 1)) ;;
			esac
		done <<<"$listing"
		[[ "$count" -lt "$threshold" ]] || return 0
	done < <(_missing_metadata_repo_paths)
	return 1
}

# The lifecycle registry does not inventory old interactive sessions. Reuse the
# clean proof/lease path under this same async lock, never in dispatch admission.
# The cursor and hard shared budget bound slow archive/removal work across runs.
_recover_interactive_capacity() {
	local helper="${SCRIPT_DIR}/worktree-helper.sh"
	local cursor="${LOG_DIR}/cleanup_worktrees.capacity-repo"
	local max_count="" threshold=""
	local repo="" saved="" start=0 offset=0 index=0 count=0 after=0 rc=0 listing=""
	local deadline=$((SECONDS + 120)) remaining=0
	local repos=()
	[[ -x "$helper" ]] && declare -F timeout_sec >/dev/null 2>&1 || return 0
	[[ "${AIDEVOPS_LIFECYCLE_DISABLED:-0}" != 1 ]] || return 0
	read -r max_count threshold < <(_worktree_cap_and_threshold)
	[[ ! -f "$cursor" ]] || IFS= read -r saved <"$cursor" || true
	while IFS= read -r repo; do
		[[ -d "$repo" ]] || continue
		repos+=("$repo")
		[[ "$repo" != "$saved" ]] || start=${#repos[@]}
	done < <(_missing_metadata_repo_paths true)
	for ((offset = 0; offset < ${#repos[@]}; offset++)); do
		remaining=$((deadline - SECONDS))
		[[ "$remaining" -gt 0 ]] || break
		index=$(((start + offset) % ${#repos[@]}))
		repo="${repos[$index]}"
		printf '%s\n' "$repo" >"$cursor" || return 1
		listing=$(timeout_sec "$remaining" git -C "$repo" worktree list --porcelain) || continue
		count=$(awk '/^worktree / {n++} END {print n+0}' <<<"$listing")
		[[ "$count" -ge "$threshold" ]] || continue
		remaining=$((deadline - SECONDS))
		[[ "$remaining" -gt 0 ]] || break
		rc=0
		# --capacity never forces dirty trees or admits closed-issue-only proof.
		(cd "$repo" && timeout_sec "$remaining" bash "$helper" clean --auto --capacity) >>"$LOGFILE" 2>&1 || rc=$?
		remaining=$((deadline - SECONDS))
		if [[ "$remaining" -le 0 ]]; then
			printf '[cleanup-worktrees-async] interactive-capacity budget exhausted; progress unverified repo=%s rc=%s\n' "$repo" "$rc" >>"$LOGFILE"
			break
		fi
		listing=$(timeout_sec "$remaining" git -C "$repo" worktree list --porcelain) || continue
		after=$(awk '/^worktree / {n++} END {print n+0}' <<<"$listing")
		printf '[cleanup-worktrees-async] interactive-capacity before=%s after=%s cap=%s rc=%s repo=%s\n' \
			"$count" "$after" "$max_count" "$rc" "$repo" >>"$LOGFILE"
		if [[ "$after" -ge "$max_count" && "$after" -ge "$count" ]]; then
			printf '[cleanup-worktrees-async] capacity-stuck: gate closed, zero safe removals (no candidates, guarded or budget exhausted); repo=%s count=%s cap=%s rc=%s\n' \
				"$repo" "$after" "$max_count" "$rc" >>"$LOGFILE"
		fi
	done
	return 0
}

main() {
	local mode="${1:-normal}"
	local repo="${2:-}"
	local budget="${3:-60}"
	local capacity_mode="--capacity"
	local lifecycle_only_mode="--lifecycle-only"
	case "$mode" in
	normal | --lifecycle-only) ;;
	--capacity)
		[[ "$repo" == /* && "$budget" =~ ^[1-9][0-9]{0,4}$ ]] || return 1
		git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || return 1
		;;
	*) printf '%s\n' 'Usage: cleanup-worktrees-async-helper.sh [--lifecycle-only | --capacity REPO SECONDS]' >&2; return 1 ;;
	esac
	local lock_started="$SECONDS"
	local lock_wait=0
	if [[ "$mode" == "$capacity_mode" ]]; then
		# Spend at most a third of this admission budget (capped at 15s)
		# waiting for the background holder; never steal a live cleanup lock.
		lock_wait=$((budget / 3))
		[[ "$lock_wait" -le 15 ]] || lock_wait=15
	fi
	while ! _lock_acquire; do
		if [[ "$mode" == "$capacity_mode" && $((SECONDS - lock_started)) -lt "$lock_wait" ]]; then
			sleep 1
			continue
		fi
		echo "[cleanup-worktrees-async] ${_LOCK_SKIP_REASON:-Lock unavailable} — skipping this invocation" >>"$LOGFILE"
		[[ "$mode" != "$capacity_mode" ]] || return 75
		return 0
	done
	if [[ "$mode" == "$capacity_mode" ]]; then
		budget=$((budget - (SECONDS - lock_started)))
		[[ "$budget" -gt 0 ]] || return 124
	fi
	_rotate_log_if_oversize
	echo "[cleanup-worktrees-async] PID=$$ starting at $(date -u '+%Y-%m-%dT%H:%M:%SZ')" >>"$LOGFILE"

	if [[ "$mode" == "$capacity_mode" ]]; then
		# Admission shares the async lock, but not its cadence or unrelated
		# maintenance/deletion scope. A timeout leaves the next job checkpointed.
		# shellcheck source=pulse-cleanup-progress.sh
		source "${SCRIPT_DIR}/pulse-cleanup-progress.sh" || return 1
		_pc_cleanup_resumable_unlocked "$budget" "$repo"
		return $?
	fi

	# Pressure kicks bypass routine cadence, never the single-runner lock. The
	# lifecycle pass has its own cursor/budget and is not in dispatch's 60s stage.
	local pressure=0
	if _worktree_pressure_present; then
		pressure=1
	fi
	if [[ "$pressure" -eq 0 ]] && ! _cadence_ok; then
		return 0
	fi
	local lifecycle_only=0
	[[ "$mode" != "$lifecycle_only_mode" ]] || lifecycle_only=1
	# --lifecycle-only keeps the routine budget: worktree-lifecycle-helper.sh
	# runs that mode under an 840 s timeout, and a kill mid-removal strands it.
	local cleanup_budget="$_CLEANUP_WORKTREES_ROUTINE_BUDGET"
	if [[ "$pressure" -eq 1 && "$lifecycle_only" -eq 0 ]]; then
		cleanup_budget="$CLEANUP_WORKTREES_PRESSURE_BUDGET"
		echo "[cleanup-worktrees-async] cleanup budget=${cleanup_budget} reason=${WORKTREE_PRESSURE_REASON}" >>"$LOGFILE"
	fi
	_run_cleanup_pass "$cleanup_budget" "$lifecycle_only"
	return 0
}

# Run the guarded cleanup pass under the held async lock and log its outcome.
# $1: cleanup_worktrees budget in seconds; $2: 1 for --lifecycle-only scope.
_run_cleanup_pass() {
	local cleanup_budget="$1"
	local lifecycle_only="$2"
	echo "[cleanup-worktrees-async] Starting cleanup_worktrees (cadence OK)" >>"$LOGFILE"
	_reconcile_worktree_registry
	_reconcile_lifecycle_receipts
	_prune_missing_worktree_metadata_all_repos
	_reclaim_branch_cleanup_transports_all_repos

	local rc=0
	local outcome="success"
	local removed_count="0"
	local archived_count="0"
	local archive_failed_count="0"
	local log_first_line=0
	local skip_reasons="none"
	log_first_line=$(wc -l <"$LOGFILE" | tr -d '[:space:]') || log_first_line=0
	cleanup_worktrees "$cleanup_budget" || rc=$?
	if [[ "$lifecycle_only" -eq 0 ]]; then
		_recover_interactive_capacity
		_prune_dirty_worktree_backups
		_prune_turbo_caches
	fi

	if [[ "${CLEANUP_WORKTREES_SKIPPED:-0}" == "1" ]]; then
		outcome="safety-skip"
		echo "[cleanup-worktrees-async] cleanup_worktrees skipped by safety gate — last-run NOT updated" >>"$LOGFILE"
	elif [[ "$rc" -eq 0 ]]; then
		if [[ "$lifecycle_only" -eq 0 ]]; then
			_maintain_worktree_recovery
			_maintain_compact_archives
		fi
		_update_last_run
		echo "[cleanup-worktrees-async] Completed successfully at $(date -u '+%Y-%m-%dT%H:%M:%SZ'). last-run updated." >>"$LOGFILE"
	else
		outcome="failed"
		echo "[cleanup-worktrees-async] cleanup_worktrees exited with rc=${rc} — last-run NOT updated" >>"$LOGFILE"
	fi
	removed_count="${CLEANUP_WORKTREES_REMOVED_COUNT:-0}"
	archived_count="${CLEANUP_WORKTREES_ARCHIVED_COUNT:-0}"
	archive_failed_count="${CLEANUP_WORKTREES_ARCHIVE_FAILED_COUNT:-0}"
	[[ "$removed_count" =~ ^[0-9]+$ ]] || removed_count=0
	[[ "$archived_count" =~ ^[0-9]+$ ]] || archived_count=0
	[[ "$archive_failed_count" =~ ^[0-9]+$ ]] || archive_failed_count=0
	skip_reasons=$(_skip_reason_summary "$log_first_line") || skip_reasons="unavailable"
	printf '%s\n' "[cleanup-worktrees-async] outcome=${outcome} removed=${removed_count} archived=${archived_count} archive_failed=${archive_failed_count} skip_reasons=${skip_reasons}" >>"$LOGFILE"

	return 0
}

main "$@"
