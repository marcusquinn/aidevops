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
#   trash          todo-sync-trash-retention.sh (trashed TODO-sync clones in
#                  ~/.Trash past the age cutoff or newest-N cap; GH#37214)
#   gitlocks       canonical-recovery-helper.sh repair-stale-locks (stale,
#                  unheld Git lock files and interrupted-fetch pack temporaries
#                  in registered canonical repositories; audited; GH#39722)
#   quarantine     pulse-stats-helper.sh prune-quarantine (newest 5 corrupt
#                  stats copies retained; GH#40197)
#   docker         docker-resource-helper.sh reap + prune-cache: only images
#                  labelled sh.aidevops.owner=1 (closed issue or TTL) and
#                  BuildKit cache unused for the window; never unlabelled
#                  images or volumes (GH#40282)
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
#   AIDEVOPS_LEGACY_WORKTREE_BASES   Colon-separated older bases to report alongside
#                                    the configured one (the historical default
#                                    base, _worktrees under the Git root, is
#                                    always checked; GH#40476)
#   STORAGE_CLEANUP_DOCKER_MAX_SECONDS  docker reap work budget (default 300)
#   AIDEVOPS_DOCKER_BUILD_CACHE_HOURS   BuildKit cache unused window (default 168)
#   STORAGE_CLEANUP_GITLOCKS_REPO_MAX_SECONDS  gitlocks budget per repository (default 120)
#   AIDEVOPS_REPOS_JSON              Repository registry (default ~/.config/aidevops/repos.json)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=./shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"
# shellcheck source=./worktree-paths.sh
source "${SCRIPT_DIR}/worktree-paths.sh"

readonly SC_STORES="tmp worktrees artefacts opencode observability trash gitlocks quarantine docker"
readonly SC_SCHEDULE_NAME="storage-hygiene"
readonly SC_APPLY="apply" SC_DRY_RUN="dry-run"
SC_SIZE_TIMEOUT="${STORAGE_CLEANUP_SIZE_TIMEOUT:-30}"
[[ "$SC_SIZE_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || SC_SIZE_TIMEOUT=30
SC_TMP_MAX_SECONDS="${STORAGE_CLEANUP_TMP_MAX_SECONDS:-300}"
[[ "$SC_TMP_MAX_SECONDS" =~ ^[0-9]+$ ]] || SC_TMP_MAX_SECONDS=300
SC_ARTEFACT_MAX_SECONDS="${STORAGE_CLEANUP_ARTEFACT_MAX_SECONDS:-300}"
[[ "$SC_ARTEFACT_MAX_SECONDS" =~ ^[1-9][0-9]*$ ]] || SC_ARTEFACT_MAX_SECONDS=300
SC_GITLOCKS_REPO_MAX_SECONDS="${STORAGE_CLEANUP_GITLOCKS_REPO_MAX_SECONDS:-120}"
[[ "$SC_GITLOCKS_REPO_MAX_SECONDS" =~ ^[1-9][0-9]*$ ]] || SC_GITLOCKS_REPO_MAX_SECONDS=120
SC_DOCKER_MAX_SECONDS="${STORAGE_CLEANUP_DOCKER_MAX_SECONDS:-300}"
[[ "$SC_DOCKER_MAX_SECONDS" =~ ^[1-9][0-9]*$ ]] || SC_DOCKER_MAX_SECONDS=300
# canonical-recovery-helper.sh exit status for a held recovery lock (skip).
readonly SC_GITLOCKS_BUSY=75
# Symlink lock: the link target is the holder PID, so the lock and its owner
# are published in one atomic syscall (no empty-lock window).
SC_LOCK="${AIDEVOPS_LOG_DIR:-${HOME:?}/.aidevops/logs}/storage-cleanup.lock"
readonly SC_LOCK_BUSY=2
# Per-base worktree sizes, set by _sc_worktree_bases_measure (GH#40476).
SC_WT_KB="" SC_WT_COUNT=0 SC_WT_BASES=0 SC_WT_BASE_LINES=""

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
	worktrees) aidevops_worktree_base_dirs ;; # Configured base, then legacy bases.
	artefacts) ;; # Inside the worktrees total; the preview reports eligible bytes.
	opencode)
		printf '%s\n' "${XDG_DATA_HOME:-${HOME}/.local/share}/opencode" \
			"${workspace}/work/opencode-interactive" \
			"${workspace}/work/opencode-tabby-recovery" \
			"${workspace}/work/repo-layout-migrations"
		;;
	observability) printf '%s\n' "${workspace}/observability" ;;
	trash) ;;      # Only owned buckets inside ~/.Trash; sized by _sc_trash_kb.
	gitlocks) ;;   # Lock files are tiny; the preview reports candidate counts.
	quarantine) ;; # Preview reports corrupt-stats copy counts, not all logs.
	docker) ;;     # Sized by `docker system df` (_sc_docker_summary), not du.
	*) return 1 ;;
	esac
	return 0
}

_sc_store_cleaner() {
	local store="$1"
	case "$store" in
	tmp) printf '%s\n' "system-cleanup.sh: ownerless task scratch or ${AIDEVOPS_TMP_RETENTION_DAYS:-7}-day inactive entries; Trash (Linux pressure: delete)" ;;
	worktrees) printf '%s\n' "cleanup-worktrees-async-helper.sh: merged/closed worktrees, guarded removal" ;;
	artefacts) printf '%s\n' "worktree-artefact-reclaim.sh: ignored build output in worktrees idle ${AIDEVOPS_WORKTREE_IDLE_DAYS:-14}+ days moves to Trash" ;;
	opencode) printf '%s\n' "opencode-db-maintenance-helper.sh auto: VACUUM, isolated DBs, layout backups" ;;
	observability) printf '%s\n' "observability-helper.sh retention-maintenance: verified archives" ;;
	trash) printf '%s\n' "todo-sync-trash-retention.sh: TODO-sync buckets older than ${TODO_SYNC_TRASH_RETENTION_DAYS:-3}d or beyond newest ${TODO_SYNC_TRASH_MAX_COUNT:-5}" ;;
	gitlocks) printf '%s\n' "canonical-recovery-helper.sh repair-stale-locks: unheld Git locks 60+ min old, pack temporaries 2+ days old; audited" ;;
	quarantine) printf '%s\n' "pulse-stats-helper.sh prune-quarantine: retain newest 5 pulse-stats.json.corrupt.* evidence copies" ;;
	docker) printf '%s\n' "docker-resource-helper.sh reap + prune-cache: labelled (sh.aidevops.owner=1) images whose issue is closed or past TTL, BuildKit cache unused ${AIDEVOPS_DOCKER_BUILD_CACHE_HOURS:-168}h+; unlabelled images and volumes are never removed" ;;
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

# Prints KiB held by owned TODO-sync trash buckets (not the whole ~/.Trash).
_sc_trash_kb() {
	local out="" total_kib=""
	out=$(timeout_sec "$SC_SIZE_TIMEOUT" bash "${SCRIPT_DIR}/todo-sync-trash-retention.sh" report 2>/dev/null) || return 1
	total_kib="${out##*kib=}"
	total_kib="${total_kib%%[[:space:]]*}"
	[[ "$total_kib" =~ ^[0-9]+$ ]] || return 1
	printf '%s\n' "$total_kib"
	return 0
}

# Prints a one-line `docker system df` summary (read-only, bounded). Prints
# "not installed", "daemon unreachable" or "timed out" and returns 1 when
# Docker cannot be sized, so the report shows a visible reason, not a hang.
_sc_docker_summary() {
	local out="" rc=0 us=$'\x1f'
	command -v docker >/dev/null 2>&1 || { printf 'not installed\n'; return 1; }
	out=$(timeout_sec "$SC_SIZE_TIMEOUT" docker system df \
		--format "{{.Type}}${us}{{.TotalCount}}${us}{{.Size}}${us}{{.Reclaimable}}" 2>/dev/null) || rc=$?
	if [[ "$rc" -eq 124 || "$rc" -ge 128 ]]; then
		printf 'timed out after %ss\n' "$SC_SIZE_TIMEOUT"
		return 1
	fi
	if [[ "$rc" -ne 0 || -z "$out" ]]; then
		printf 'unavailable (daemon unreachable or docker system df failed)\n'
		return 1
	fi
	printf '%s\n' "$out" | awk -F"$us" 'NF >= 4 {
		sep = (n++ ? "; " : "")
		printf "%s%s %s (reclaimable %s)", sep, tolower($1), $3, $4
	} END { printf "\n" }'
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

# Directory entries in one base (default: the configured base).
_sc_worktree_count() {
	local base="${1:-}" count=0 entry=""
	[[ -n "$base" ]] || base=$(aidevops_worktree_base_dir_configured)
	[[ -d "$base" ]] || { printf '0\n'; return 0; }
	for entry in "$base"/*; do
		[[ -d "$entry" ]] && count=$((count + 1))
	done
	printf '%s\n' "$count"
	return 0
}

# Sizes every worktree base once for the report (GH#40476). Sets SC_WT_KB
# (total KiB; empty when any base timed out), SC_WT_COUNT, SC_WT_BASES and
# SC_WT_BASE_LINES ("configured|legacy PATH: N worktrees (SIZE)" per base).
_sc_worktree_bases_measure() {
	local kb=""
	local base="" size="" count=0 label="configured"
	SC_WT_KB=0 SC_WT_COUNT=0 SC_WT_BASES=0 SC_WT_BASE_LINES=""
	while IFS= read -r base; do
		[[ -n "$base" ]] || continue
		count=$(_sc_worktree_count "$base")
		SC_WT_COUNT=$((SC_WT_COUNT + count))
		SC_WT_BASES=$((SC_WT_BASES + 1))
		if kb=$(_sc_path_kb "$base"); then
			size=$(_sc_human_kb "$kb")
			[[ -n "$SC_WT_KB" ]] && SC_WT_KB=$((SC_WT_KB + kb))
		else
			size="?"
			SC_WT_KB=""
		fi
		SC_WT_BASE_LINES="${SC_WT_BASE_LINES}${label} ${base}: ${count} worktrees (${size})"$'\n'
		label="legacy"
	done < <(aidevops_worktree_base_dirs)
	return 0
}

# Explains why a legacy base's entries survive, read-only and without Git
# calls (GH#40476). Prints "TOTAL MANAGED IN_SCOPE UNMANAGED STALE OTHER":
# managed = registered with a repos.json repository (lifecycle cleanup owns
# it; relocate moves it only when it sits inside that repo's parent and the
# repo is not local_only), unmanaged = registered with another repository,
# stale = the .git pointer target is missing, other = not a linked worktree.
_sc_classify_legacy_base() {
	local base="$1" repos="$2" entry="" pointer="" gitdir="" common="" canonical="" physical=""
	local repo_parent="" repo_path="" local_only="" matched=""
	local total=0 managed=0 in_scope=0 unmanaged=0 stale=0 other=0
	for entry in "$base"/*; do
		[[ -d "$entry" && ! -L "$entry" ]] || continue
		total=$((total + 1))
		pointer=""
		[[ -f "${entry}/.git" ]] && { IFS= read -r pointer <"${entry}/.git" || true; }
		gitdir="${pointer#gitdir: }"
		if [[ -z "$pointer" || "$gitdir" == "$pointer" || -z "$gitdir" ]]; then
			other=$((other + 1))
			continue
		fi
		[[ "$gitdir" == /* ]] || gitdir="${entry}/${gitdir}"
		if [[ ! -d "$gitdir" ]]; then
			stale=$((stale + 1))
			continue
		fi
		common=$(aidevops_physical_dir "${gitdir}/../..") || common=""
		canonical="${common%/.git}"
		matched=""
		if [[ -n "$common" && "$canonical" != "$common" ]]; then
			while IFS=$'\t' read -r repo_path local_only; do
				[[ "$repo_path" == "$canonical" ]] && { matched="$local_only"; break; }
			done <<<"$repos"
		fi
		if [[ -z "$matched" ]]; then
			unmanaged=$((unmanaged + 1))
			continue
		fi
		managed=$((managed + 1))
		physical=$(aidevops_physical_dir "$entry") || physical=""
		repo_parent="${canonical%/*}"
		if [[ "$matched" == "false" && -n "$physical" && "$physical" == "$repo_parent"/* ]]; then
			in_scope=$((in_scope + 1))
		fi
	done
	printf '%s %s %s %s %s %s\n' "$total" "$managed" "$in_scope" "$unmanaged" "$stale" "$other"
	return 0
}

# Registered repositories as "physical-path<TAB>local_only" lines.
_sc_registry_repo_physicals() {
	local registry="${AIDEVOPS_REPOS_JSON:-${HOME}/.config/aidevops/repos.json}" path="" local_only="" physical=""
	[[ -f "$registry" ]] && command -v jq >/dev/null 2>&1 || return 0
	while IFS=$'\t' read -r path local_only; do
		[[ "$path" == /* ]] || continue
		physical=$(aidevops_physical_dir "$path") || continue
		printf '%s\t%s\n' "$physical" "$local_only"
	done < <(jq -r '.initialized_repos[]? | [(.path // ""), ((.local_only // false) | tostring)] | @tsv' "$registry" 2>/dev/null || true)
	return 0
}

# Worktrees preview: the configured base, then one classified line per
# legacy base so worktrees left behind by a base move stay visible.
_sc_preview_worktrees() {
	local base="" repos="" counts="" total=0 managed=0 in_scope=0 unmanaged=0 stale=0 other=0 legacy=0
	printf 'Linked worktrees: %s under %s%s\n' "$(_sc_worktree_count)" "$(aidevops_worktree_base_dir_configured)" "$(_sc_last_worktree_refusals)"
	while IFS= read -r base; do
		[[ -n "$base" ]] || continue
		[[ "$legacy" -eq 1 ]] || repos=$(_sc_registry_repo_physicals)
		legacy=1
		counts=$(_sc_classify_legacy_base "$base" "$repos")
		read -r total managed in_scope unmanaged stale other <<<"$counts"
		printf 'Legacy base %s: %s entries; managed %s (relocate scope %s), unmanaged %s, stale %s, other %s\n' \
			"$base" "$total" "$managed" "$in_scope" "$unmanaged" "$stale" "$other"
	done < <(aidevops_legacy_worktree_base_dirs)
	if [[ "$legacy" -eq 1 ]]; then
		printf '%s\n' "Legacy bases are reported, not swept wholesale: lifecycle cleanup still removes merged/closed managed worktrees there; relocate moves only managed worktrees inside their repo's parent; other entries get the guarded orphan and unregistered scans. More bases: AIDEVOPS_LEGACY_WORKTREE_BASES (colon-separated)."
	fi
	printf 'Apply removes only worktrees whose branches are merged or closed; dirty work is archived first.\n'
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
	local store="" kb="" size="" note="" line="" wt_lines="" timed_out=0
	printf 'aidevops storage report (read-only; nothing is deleted)\n\n'
	printf '%-14s %-9s %s\n' "STORE" "SIZE" "OWNING CLEANER"
	for store in $SC_STORES; do
		note=""
		wt_lines=""
		if [[ "$store" == "artefacts" ]]; then
			# Counted inside worktrees; eligibility needs the bounded preview.
			size="(in wt)"
		elif [[ "$store" == "gitlocks" || "$store" == "quarantine" ]]; then
			# Counted by the bounded preview; the files themselves are tiny.
			size="(count)"
		elif [[ "$store" == "docker" ]]; then
			# Docker reports its own totals; shown as a note below the row.
			size="(df)"
		elif [[ "$store" == "trash" ]]; then
			if kb=$(_sc_trash_kb); then
				size=$(_sc_human_kb "$kb")
			else
				size="?"
				timed_out=1
			fi
		elif [[ "$store" == "worktrees" ]]; then
			# Sized per base once, so legacy bases show beside the total.
			_sc_worktree_bases_measure
			if [[ -n "$SC_WT_KB" ]]; then
				size=$(_sc_human_kb "$SC_WT_KB")
			else
				size="?"
				timed_out=1
			fi
			note=" (${SC_WT_COUNT} worktrees)"
			[[ "$SC_WT_BASES" -gt 1 ]] && wt_lines="$SC_WT_BASE_LINES"
		elif kb=$(_sc_store_kb "$store"); then
			size=$(_sc_human_kb "$kb")
		else
			size="?"
			timed_out=1
		fi
		printf '%-14s %-9s %s%s\n' "$store" "$size" "$(_sc_store_cleaner "$store")" "$note"
		while IFS= read -r line; do
			if [[ -n "$line" ]]; then printf '%-14s %-9s %s\n' "" "" "$line"; fi
		done <<<"$wt_lines"
		if [[ "$store" == "docker" ]]; then
			printf '%-14s %-9s %s\n' "" "" "docker system df: $(_sc_docker_summary || true)"
		fi
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

# Report TODO-sync trash buckets (dry-run prune) plus the orphan-cleanup class,
# which shares ~/.Trash but is only reported: it may hold unique work.
_sc_preview_trash() {
	local rc=0
	bash "${SCRIPT_DIR}/todo-sync-trash-retention.sh" prune || rc=$?
	bash "${SCRIPT_DIR}/todo-sync-trash-retention.sh" orphan-report || true
	printf 'Apply permanently deletes only the TODO-sync buckets listed above.\n'
	return "$rc"
}

# Registered canonical checkouts (a .git directory, not a linked-worktree file).
# An absent registry is a no-op; an unreadable one is an error (returns 1).
_sc_canonical_repos() {
	local registry="${AIDEVOPS_REPOS_JSON:-${HOME}/.config/aidevops/repos.json}" path="" paths=""
	[[ -f "$registry" ]] || return 0
	command -v jq >/dev/null 2>&1 || {
		printf 'gitlocks: jq is required to read %s\n' "${registry##*/}" >&2
		return 1
	}
	paths=$(jq -r '.initialized_repos[]?.path // empty' "$registry" 2>/dev/null) || {
		printf 'gitlocks: cannot parse repository registry %s\n' "${registry##*/}" >&2
		return 1
	}
	while IFS= read -r path; do
		[[ "$path" == /* && -d "${path}/.git" ]] && printf '%s\n' "$path"
	done <<<"$paths"
	return 0
}

# Human size for a byte count.
_sc_human_bytes() {
	local bytes="$1"
	[[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
	_sc_human_kb "$(((bytes + 1023) / 1024))"
	return 0
}

# Runs repair-stale-locks (preview or --apply) per canonical repository and
# prints a line for each repository with findings or errors, then a total.
# Pack temporaries are sized even while the age gate keeps them (GH#40476).
# The helper enforces every age/holder gate.
_sc_gitlocks() {
	local mode="$1" repo="" out="" rc=0 repo_rc=0 repos=0 locks="" packs="" removed="" found=0
	local repo_list="" pack_bytes=0 young_bytes=0 young_note="" total_pack_bytes=0 total_young_bytes=0
	local -a apply_args=()
	[[ "$mode" == "$SC_APPLY" ]] && apply_args=(--apply)
	repo_list=$(_sc_canonical_repos) || return 1
	while IFS= read -r repo; do
		[[ -n "$repo" ]] || continue
		repos=$((repos + 1))
		repo_rc=0
		out=$(timeout_sec "$SC_GITLOCKS_REPO_MAX_SECONDS" bash "${SCRIPT_DIR}/canonical-recovery-helper.sh" \
			repair-stale-locks --repo "$repo" "${apply_args[@]+"${apply_args[@]}"}" 2>&1) || repo_rc=$?
		locks=$(sed -n 's/^STALE_LOCK_CANDIDATES=//p' <<<"$out")
		packs=$(sed -n 's/^TMP_PACK_CANDIDATES=//p' <<<"$out")
		removed=$(sed -n 's/^REMOVED=//p' <<<"$out")
		pack_bytes=$(sed -n 's/^TMP_PACK_BYTES=//p' <<<"$out")
		young_bytes=$(sed -n 's/^TMP_PACK_YOUNG_BYTES=//p' <<<"$out")
		[[ "$pack_bytes" =~ ^[0-9]+$ ]] || pack_bytes=0
		[[ "$young_bytes" =~ ^[0-9]+$ ]] || young_bytes=0
		if [[ "$repo_rc" -eq "$SC_GITLOCKS_BUSY" ]]; then
			printf '  %s: skipped (canonical recovery lock held)\n' "${repo##*/}"
			continue
		fi
		[[ "$repo_rc" -eq 0 && "$locks" == "0" && "$packs" == "0" && "$pack_bytes" -eq 0 ]] && continue
		found=$((found + 1))
		total_pack_bytes=$((total_pack_bytes + pack_bytes))
		total_young_bytes=$((total_young_bytes + young_bytes))
		young_note=""
		[[ "$young_bytes" -gt 0 ]] && young_note=" (young $(_sc_human_bytes "$young_bytes") kept until 2+ days old)"
		printf '  %s: stale_locks=%s tmp_packs=%s tmp_pack_bytes=%s%s%s\n' "${repo##*/}" "${locks:-?}" "${packs:-?}" \
			"$(_sc_human_bytes "$pack_bytes")" "$young_note" "${removed:+ removed=${removed}}"
		grep -E '^(CANDIDATE|REMOVED|KEPT) ' <<<"$out" | sed 's/^/    /' || true
		if [[ "$repo_rc" -ne 0 ]]; then
			printf '    exit %s: %s\n' "$repo_rc" "$(awk '/^(BLOCKED|FAILED)/ && !seen { print; seen = 1 }' <<<"$out")"
			rc=1
		fi
	done <<<"$repo_list"
	printf 'Scanned %s canonical repositories; %s with Git debris or errors.\n' "$repos" "$found"
	if [[ "$total_pack_bytes" -gt 0 ]]; then
		printf 'Pack temporaries: %s found, %s still inside the 2-day age gate (kept).\n' \
			"$(_sc_human_bytes "$total_pack_bytes")" "$(_sc_human_bytes "$total_young_bytes")"
	fi
	[[ "$mode" == "$SC_APPLY" ]] || printf 'Apply removes only the candidates listed above, re-checking each gate.\n'
	return "$rc"
}

_sc_dry_run_store() {
	local store="$1" rc=0
	case "$store" in
	tmp) _sc_preview_tmp || rc=$? ;;
	worktrees) _sc_preview_worktrees || rc=$? ;;
	artefacts) _sc_preview_artefacts || rc=$? ;;
	opencode)
		printf 'Superseded/expired layout-migration backups (dry run):\n'
		bash "${SCRIPT_DIR}/repo-layout-migrate-helper.sh" prune || rc=$?
		printf 'Archived event retention (conversation history preserved):\n'
		bash "${SCRIPT_DIR}/opencode-db-archive.sh" archive-all --events-only --dry-run || rc=$?
		_sc_preview_opencode_retention || rc=$?
		bash "${SCRIPT_DIR}/opencode-db-maintenance-helper.sh" reclaimable || true
		printf 'Apply also checkpoints/optimizes each idle OpenCode DB (throttled to weekly).\n'
		;;
	observability)
		bash "${SCRIPT_DIR}/observability-helper.sh" retention-maintenance --dry-run \
			--max-partitions 20 --max-duration-seconds 120 || rc=$?
		;;
	trash) _sc_preview_trash || rc=$? ;;
	gitlocks) _sc_gitlocks "$SC_DRY_RUN" || rc=$? ;;
	quarantine) bash "${SCRIPT_DIR}/pulse-stats-helper.sh" prune-quarantine || rc=$? ;;
	docker)
		bash "${SCRIPT_DIR}/docker-resource-helper.sh" reap --images-only --dry-run --max-seconds "$SC_DOCKER_MAX_SECONDS" || rc=$?
		bash "${SCRIPT_DIR}/docker-resource-helper.sh" prune-cache --dry-run || rc=$?
		;;
	*) return 1 ;;
	esac
	return "$rc"
}

# Refusals from the last async cleanup pass (GH#39034), as a suffix for the
# "Linked worktrees" line: " (last pass: refused=N skip_reasons=...)" or empty.
_sc_last_worktree_refusals() {
	local log="${AIDEVOPS_LOG_DIR:-${HOME}/.aidevops/logs}/cleanup_worktrees.log" line="" refused="" reasons=""
	[[ -f "$log" ]] || return 0
	line=$(grep -F '[cleanup-worktrees-async] outcome=' "$log" 2>/dev/null | tail -n 1) || line=""
	[[ "$line" == *" refused="* ]] || return 0
	refused="${line##* refused=}"
	refused="${refused%% *}"
	[[ "$refused" =~ ^[0-9]+$ ]] || return 0
	reasons="${line##* skip_reasons=}"
	[[ "$reasons" != "$line" ]] || reasons="unavailable"
	printf ' (last pass: refused=%s skip_reasons=%s)' "$refused" "$reasons"
	return 0
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
	opencode)
		bash "${SCRIPT_DIR}/opencode-db-archive.sh" archive-all --events-only --apply || rc=$?
		bash "${SCRIPT_DIR}/opencode-db-maintenance-helper.sh" auto || rc=$?
		;;
	observability)
		bash "${SCRIPT_DIR}/observability-helper.sh" retention-maintenance --apply \
			--max-partitions 20 --max-duration-seconds 120 || rc=$?
		;;
	trash) bash "${SCRIPT_DIR}/todo-sync-trash-retention.sh" prune --apply || rc=$? ;;
	gitlocks) _sc_gitlocks "$SC_APPLY" || rc=$? ;;
	quarantine) bash "${SCRIPT_DIR}/pulse-stats-helper.sh" prune-quarantine --apply || rc=$? ;;
	docker)
		bash "${SCRIPT_DIR}/docker-resource-helper.sh" reap --images-only --apply --max-seconds "$SC_DOCKER_MAX_SECONDS" || rc=$?
		bash "${SCRIPT_DIR}/docker-resource-helper.sh" prune-cache --apply || rc=$?
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
  maintenance plan --repo PATH
                        Plan legacy worktrees; no removal or registry writes
  maintenance check|apply --plan FILE --confirm TOKEN
                        Explicit offline maintenance; never part of all --apply

Every store is cleaned by its existing owner with that owner's safety gates;
this command never deletes files itself. The daily r922 Storage hygiene routine
runs 'all --apply' automatically once setup.sh/aidevops update installs it.
EOF
	return 0
}

main() {
	local subcommand="${1:-report}" mode="$SC_DRY_RUN" arg=""
	[[ $# -gt 0 ]] && shift
	if [[ "$subcommand" == "maintenance" ]]; then
		PYTHONDONTWRITEBYTECODE=1 python3 "${SCRIPT_DIR}/worktree-maintenance.py" "$@" || return 1
		return 0
	fi
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
