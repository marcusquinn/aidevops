#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-dispatch-core.sh — Core worker dispatch primitives — dedup check, issue lock/unlock, impl-commit detection, main-commit check, large-file gate, dispatch_with_dedup orchestrator + helpers, terminal blocker matching.
#
# Extracted from pulse-wrapper.sh in Phase 9 of the phased decomposition
# (parent: GH#18356, plan: todo/plans/pulse-wrapper-decomposition.md §6).
# Phase 9 is the highest-risk phase — core dispatch logic.
#
# This module is sourced by pulse-wrapper.sh. Depends on shared-constants.sh
# and worker-lifecycle-common.sh being sourced first by the orchestrator.
#
# Issue locks, worker discovery, and commit/approval gates are defined in the
# sibling libraries below. This module retains capacity gates, dedup orchestration,
# brief validation, and terminal blocker handling.
#
# Extracted sub-modules (sourced below):
#   - pulse-dispatch-locks.sh          — worker discovery, issue locks, commit detection
#   - pulse-dispatch-commit-gates.sh   — trust, approval, label and main-commit gates
#   - pulse-dispatch-dedup-layers.sh    — 7-layer dedup chain + stale classifier
#   - pulse-dispatch-large-file-gate.sh — large-file simplification gate
#   - pulse-dispatch-worker-launch.sh   — worker launch helpers + orchestrator
#   - dispatch-dedup-footprint.sh       — file-footprint overlap throttle (t2117)
#   - pre-dispatch-eligibility-helper.sh — generic eligibility gate: CLOSED, status:done, recent-merge (t2424)
#   - pulse-stats-helper.sh             — operational counters: pre_dispatch_aborts_24h (t2424)
#
# Pure move from pulse-wrapper.sh. Byte-identical function bodies.
# Phase 12 post-gate simplification: _is_task_committed_to_main split into
# _task_id_in_recent_commits, _task_id_in_merged_pr, _task_id_in_changed_files
# (t2004). Phase 12 (t1999): dispatch_with_dedup split into decision helper
# (_dispatch_dedup_check_layers) + action helper (_dispatch_launch_worker)
# + thin orchestrator. External signature of dispatch_with_dedup unchanged.
# GH#18832: extracted dedup layers, large-file gate, and worker launch helpers
# into sub-modules to bring this file below the 2000-line simplification gate.

[[ -n "${_PULSE_DISPATCH_CORE_LOADED:-}" ]] && return 0
_PULSE_DISPATCH_CORE_LOADED=1
_PULSE_DISPATCH_FALSE="false"
_PULSE_DISPATCH_OPEN_STATE="OPEN"
_PULSE_DISPATCH_ELIGIBILITY_STAGE="eligibility_gate"
_PULSE_DISPATCH_NMR_LABEL="needs-maintainer-review"
_PULSE_DISPATCH_COLLABORATOR_ASSOCIATION="COLLABORATOR"
_PULSE_DISPATCH_AUTO_LABEL="auto-dispatch"
_PULSE_DISPATCH_JSON_ARRAY_TYPE="array"
_PULSE_DISPATCH_UNSIGNED_INTEGER_PATTERN='^[0-9]+$'
_PULSE_DISPATCH_DEDUP_LABEL_CHECK_STAGE="dedup.label_checks"
# One Pulse invocation sources this module once. This guard therefore bounds
# synchronous global disk-pressure recovery to one guarded cleanup per cycle.
AIDEVOPS_DISPATCH_DISK_PRESSURE_CLEANUP_ATTEMPTED=0

# t2863: Module-level variable defaults (set -u guards).
# Ensures LOGFILE is safe to dereference in all functions when this module
# is sourced outside the pulse-wrapper.sh bootstrap context.
: "${LOGFILE:=${HOME}/.aidevops/logs/pulse.log}"

# shellcheck source=disk-capacity-lib.sh
source "${BASH_SOURCE[0]%/*}/disk-capacity-lib.sh"
# shellcheck source=renovate-dependency-dashboard-helper.sh
source "${BASH_SOURCE[0]%/*}/renovate-dependency-dashboard-helper.sh"

# Extracted modules — sourced in load order.
# shellcheck source=pulse-dispatch-dedup-layers.sh
source "${BASH_SOURCE[0]%/*}/pulse-dispatch-dedup-layers.sh"
# shellcheck source=pulse-dispatch-large-file-gate.sh
source "${BASH_SOURCE[0]%/*}/pulse-dispatch-large-file-gate.sh"
# GH#32689: brief-scope normalization and repaired-hold release
# shellcheck source=pulse-dispatch-brief-scope.sh
source "${BASH_SOURCE[0]%/*}/pulse-dispatch-brief-scope.sh"
# shellcheck source=pulse-dispatch-worker-launch.sh
source "${BASH_SOURCE[0]%/*}/pulse-dispatch-worker-launch.sh"
# t2117/GH#19109: file-footprint overlap throttle
# shellcheck source=dispatch-dedup-footprint.sh
source "${BASH_SOURCE[0]%/*}/dispatch-dedup-footprint.sh"
# t2424/GH#20030: generic pre-dispatch eligibility gate (CLOSED, status:done, recent-merge)
# shellcheck source=pre-dispatch-eligibility-helper.sh
source "${BASH_SOURCE[0]%/*}/pre-dispatch-eligibility-helper.sh"
# t2424/GH#20030: pulse operational counters (pre_dispatch_aborts_24h)
# shellcheck source=pulse-stats-helper.sh
source "${BASH_SOURCE[0]%/*}/pulse-stats-helper.sh"
# t3034: per-stage dispatch ceremony timing instrumentation
# shellcheck source=dispatch-stage-instrument.sh
source "${BASH_SOURCE[0]%/*}/dispatch-stage-instrument.sh"
if ! declare -F _gh_collaborator_permission_lookup >/dev/null 2>&1; then
	# shellcheck source=shared-gh-collaborator-permission.sh
	source "${BASH_SOURCE[0]%/*}/shared-gh-collaborator-permission.sh"
fi

# Dispatch issue locks and commit/approval gates are loaded in original order.
# shellcheck source=pulse-dispatch-locks.sh
source "${BASH_SOURCE[0]%/*}/pulse-dispatch-locks.sh"
# shellcheck source=pulse-dispatch-commit-gates.sh
source "${BASH_SOURCE[0]%/*}/pulse-dispatch-commit-gates.sh"

_dispatch_has_interactive_hold() {
	local issue_meta_json="$1"
	[[ -n "$issue_meta_json" ]] || return 1
	printf '%s' "$issue_meta_json" |
		jq -e --arg auto_dispatch_label "$_PULSE_DISPATCH_AUTO_LABEL" '
			([.labels[]?.name]) as $labels |
			(($labels | index($auto_dispatch_label)) | not) and
			(
				($labels | index("status:in-review")) or
				(($labels | index("origin:interactive")) and (((.assignees // []) | length) > 0))
			)
		' >/dev/null 2>&1
	return $?
}

#######################################
# Pre-dispatch validation + dedup check layers for dispatch_with_dedup.
# Extracted from dispatch_with_dedup (t1999, Phase 12) to reduce the
# parent function to a thin orchestrator.
#
# Runs all pre-dispatch safety gates in order:
#   1. Issue state (must be OPEN)
#   2. Management labels (supervisor/contributor/persistent/etc.)
#   3. External issue author gate (GH#22399 — Actions queue race)
#   4. Cryptographic approval gate (t1894, ever-NMR)
#   5. Supervisor telemetry title guard
#   6. Main-commit check (GH#17574 — task already done)
#   7. Blocked-by dependency enforcement (t1927)
#   8. Issue consolidation pre-check
#   9. Large-file simplification gate
#   10. Read-only check_dispatch_dedup chain (Layers 1–6)
#       Layer 7 claim lock runs after canary preflight in worker launch.
#
# Arguments:
#   $1 - issue_number
#   $2 - repo_slug (owner/repo)
#   $3 - dispatch_title (normalized title used as dedup key)
#   $4 - issue_title (raw issue title, may differ from dispatch_title)
#   $5 - self_login (dispatching runner login)
#   $6 - repo_path (local path to the repo)
#   $7 - issue_meta_json (pre-fetched JSON: number,title,state,labels,assignees)
#
# Exit codes:
#   0 - all gates passed; safe to dispatch
#   1 - blocked (reason logged to LOGFILE by the failing gate)
#   3 - expected benign dispatch block with structured DISPATCH_BLOCK_REASON
#######################################
# Count live registered worktrees. Git marks entries whose directory vanished
# outside aidevops (for example a reboot wiping /tmp) as `prunable`; they hold
# no disk and must not consume dispatch capacity (GH#32913). Locked entries are
# never marked prunable, so they remain counted and the gate stays fail-closed.
_dispatch_registered_worktree_count() {
	local repo_path="$1"
	local worktree_list=""
	local line=""
	local total=0
	local prunable=0
	local count=""
	worktree_list=$(git -C "$repo_path" worktree list --porcelain 2>/dev/null) || return 1
	[[ -n "$worktree_list" ]] || return 1
	while IFS= read -r line; do
		case "$line" in
		"worktree "*) total=$((total + 1)) ;;
		prunable | "prunable "*) prunable=$((prunable + 1)) ;;
		esac
	done <<<"$worktree_list"
	[[ "$total" -ge 1 && "$prunable" -lt "$total" ]] || return 1
	count=$((total - prunable))
	[[ "$count" =~ $_PULSE_DISPATCH_UNSIGNED_INTEGER_PATTERN ]] || return 1
	printf '%s\n' "$count"
	return 0
}

_dispatch_run_guarded_worktree_cleanup() {
	local repo_path="$1"
	local helper="$2"
	(
		cd -- "$repo_path" || exit 125
		bash "$helper" clean --auto --force-merged
	) >>"${LOGFILE:-/dev/null}" 2>&1
}

# At the dispatch worktree cap, synchronously give the existing guarded cleanup
# one bounded chance to recover capacity. The helper remains responsible for
# preserving dirty, active, open-PR, unmerged, and externally-owned worktrees.
_dispatch_cleanup_worktree_capacity() {
	local repo_path="$1"
	local issue_number="$2"
	local repo_slug="$3"
	local before_count="$4"
	local max_count="$5"
	local helper="${AIDEVOPS_WORKTREE_HELPER:-${BASH_SOURCE[0]%/*}/worktree-helper.sh}"
	local cleanup_timeout="${AIDEVOPS_DISPATCH_WORKTREE_CLEANUP_TIMEOUT:-60}"
	local cleanup_rc=0
	local after_count=""

	[[ "$cleanup_timeout" =~ $_PULSE_DISPATCH_UNSIGNED_INTEGER_PATTERN ]] || cleanup_timeout=60
	[[ "$cleanup_timeout" -ge 1 ]] || cleanup_timeout=1
	if [[ ! -x "$helper" ]]; then
		echo "[dispatch_with_dedup] Capacity cleanup unavailable for #${issue_number} in ${repo_slug}: guarded helper not executable (${helper}); count remains ${before_count}/${max_count}" >>"$LOGFILE"
		return 1
	fi
	if ! declare -F run_stage_with_timeout >/dev/null 2>&1; then
		echo "[dispatch_with_dedup] Capacity cleanup unavailable for #${issue_number} in ${repo_slug}: bounded stage runner missing; count remains ${before_count}/${max_count}" >>"$LOGFILE"
		return 1
	fi

	echo "[dispatch_with_dedup] Live worktree count ${before_count} >= cap ${max_count} for #${issue_number} in ${repo_slug}; attempting guarded cleanup (timeout ${cleanup_timeout}s)" >>"$LOGFILE"
	run_stage_with_timeout "dispatch_worktree_capacity_cleanup" "$cleanup_timeout" \
		_dispatch_run_guarded_worktree_cleanup "$repo_path" "$helper" || cleanup_rc=$?
	if ! after_count=$(_dispatch_registered_worktree_count "$repo_path"); then
		echo "[dispatch_with_dedup] Guarded capacity cleanup could not verify the post-cleanup worktree count for #${issue_number} in ${repo_slug} (before ${before_count}, cap ${max_count}, cleanup_rc=${cleanup_rc}); dispatch remains fail-closed" >>"$LOGFILE"
		return 1
	fi
	if [[ "$after_count" =~ $_PULSE_DISPATCH_UNSIGNED_INTEGER_PATTERN ]] && [[ "$after_count" -lt "$max_count" ]]; then
		echo "[dispatch_with_dedup] Guarded capacity cleanup recovered dispatch capacity for #${issue_number} in ${repo_slug}: ${before_count} -> ${after_count} worktrees (cap ${max_count}, cleanup_rc=${cleanup_rc})" >>"$LOGFILE"
		return 0
	fi

	[[ "$after_count" =~ $_PULSE_DISPATCH_UNSIGNED_INTEGER_PATTERN ]] || after_count="$before_count"
	echo "[dispatch_with_dedup] Guarded capacity cleanup could not recover dispatch capacity for #${issue_number} in ${repo_slug}: ${before_count} -> ${after_count} worktrees (cap ${max_count}, cleanup_rc=${cleanup_rc}); existing cleanup safety gates preserved remaining worktrees" >>"$LOGFILE"
	return 1
}

_dispatch_worktree_capacity_gate() {
	local repo_path="$1"
	local issue_number="$2"
	local repo_slug="$3"
	local max_count="$4"
	local count=""

	if ! count=$(_dispatch_registered_worktree_count "$repo_path"); then
		echo "[dispatch_with_dedup] Dispatch blocked for #${issue_number} in ${repo_slug}: unable to verify registered worktree count; capacity gate remains fail-closed" >>"$LOGFILE"
		return 1
	fi
	if [[ "$count" -lt "$max_count" ]]; then
		return 0
	fi
	_dispatch_cleanup_worktree_capacity "$repo_path" "$issue_number" "$repo_slug" "$count" "$max_count"
	return $?
}

_dispatch_run_guarded_disk_cleanup() {
	cleanup_worktrees "${1:-60}"
	return $?
}

# At the global worktree-filesystem capacity gate, synchronously run the
# existing all-repository guarded cleanup once per Pulse cycle, then recheck
# both capacity thresholds. The cleanup owns all destructive safety guards.
_dispatch_cleanup_disk_pressure() {
	local issue_number="$1"
	local repo_slug="$2"
	local target_path="$3"
	local before_reason="$4"
	local before_kb="$5"
	local before_percent="$6"
	local cleanup_timeout="${AIDEVOPS_DISPATCH_DISK_CLEANUP_TIMEOUT:-60}"
	local cleanup_rc=0
	local after_rc=0

	if [[ "${AIDEVOPS_DISPATCH_DISK_PRESSURE_CLEANUP_ATTEMPTED:-0}" == "1" ]]; then
		echo "[dispatch_with_dedup] Disk-pressure cleanup already attempted this Pulse cycle; dispatch remains fail-closed for #${issue_number} in ${repo_slug} (reason=${before_reason}, available=${before_kb}KB/${before_percent}%)" >>"$LOGFILE"
		return 1
	fi
	AIDEVOPS_DISPATCH_DISK_PRESSURE_CLEANUP_ATTEMPTED=1
	[[ "$cleanup_timeout" =~ $_PULSE_DISPATCH_UNSIGNED_INTEGER_PATTERN ]] || cleanup_timeout=60
	[[ "$cleanup_timeout" -ge 1 ]] || cleanup_timeout=1
	if ! declare -F cleanup_worktrees >/dev/null 2>&1; then
		echo "[dispatch_with_dedup] Disk-pressure cleanup unavailable for #${issue_number} in ${repo_slug}: guarded all-repository cleanup missing (before reason=${before_reason}, available=${before_kb}KB/${before_percent}%); dispatch remains fail-closed" >>"$LOGFILE"
		return 1
	fi
	if ! declare -F run_stage_with_timeout >/dev/null 2>&1; then
		echo "[dispatch_with_dedup] Disk-pressure cleanup unavailable for #${issue_number} in ${repo_slug}: bounded stage runner missing (before reason=${before_reason}, available=${before_kb}KB/${before_percent}%); dispatch remains fail-closed" >>"$LOGFILE"
		return 1
	fi

	echo "[dispatch_with_dedup] Disk pressure for #${issue_number} in ${repo_slug}: reason=${before_reason}, available=${before_kb}KB/${before_percent}%; attempting guarded all-repository cleanup once this Pulse cycle (timeout ${cleanup_timeout}s)" >>"$LOGFILE"
	run_stage_with_timeout "dispatch_disk_pressure_cleanup" "$cleanup_timeout" \
		_dispatch_run_guarded_disk_cleanup "$cleanup_timeout" || cleanup_rc=$?
	aidevops_worktree_capacity_check "$target_path" || after_rc=$?
	if [[ "$after_rc" -eq 0 ]]; then
		echo "[dispatch_with_dedup] Guarded disk-pressure cleanup recovered dispatch capacity for #${issue_number} in ${repo_slug}: ${before_kb}KB/${before_percent}% -> ${AIDEVOPS_DISK_CAPACITY_AVAILABLE_KB}KB/${AIDEVOPS_DISK_CAPACITY_AVAILABLE_PERCENT}% (cleanup_rc=${cleanup_rc})" >>"$LOGFILE"
		return 0
	fi

	echo "[dispatch_with_dedup] Guarded disk-pressure cleanup could not recover dispatch capacity for #${issue_number} in ${repo_slug}: before reason=${before_reason}, available=${before_kb}KB/${before_percent}%; after reason=${AIDEVOPS_DISK_CAPACITY_REASON}, available=${AIDEVOPS_DISK_CAPACITY_AVAILABLE_KB}KB/${AIDEVOPS_DISK_CAPACITY_AVAILABLE_PERCENT}% (cleanup_rc=${cleanup_rc}, capacity_rc=${after_rc}); existing cleanup safety gates preserved remaining worktrees" >>"$LOGFILE"
	return 1
}

_dispatch_dedup_capacity_gates() {
	local issue_number="$1"
	local repo_slug="$2"
	local issue_title="$3"
	local self_login="$4"
	local repo_path="$5"
	local issue_meta_json="$6"

	# t3043: per-sub-stage timing inside dedup_check. The outer
	# dispatch_with_dedup records "dedup_check" as one blob; these
	# sub-stage records let us identify which gate dominates the 235s avg.
	local _dss_t0="" _ds_stage_attempt_id=""

	# GH#22948/GH#22964/GH#29535: interactive/review holds remain independent
	# of assignee identity. A terminal worker draft checkpoint is the sole narrow
	# exception: route its existing exact PR before consuming the generic hold.
	_dss_t0=$(_ds_now_ns)
	_ds_stage_start "$issue_number" "$repo_slug" "interactive_hold" "$_dss_t0" _ds_stage_attempt_id
	if _dispatch_interactive_hold_gate "$issue_number" "$repo_slug" "$issue_title" \
		"$self_login" "$issue_meta_json"; then
		_ds_record "$issue_number" "$repo_slug" "dedup.interactive_hold" "$_dss_t0"
		return 3
	fi
	_ds_record "$issue_number" "$repo_slug" "dedup.interactive_hold" "$_dss_t0"

	# GH#18987/GH#28543: refuse dispatch when the worktree filesystem has less
	# than 5 GiB or 5% available. The same fail-closed policy runs at the actual
	# worktree creation boundary, covering interactive and non-Pulse callers.
	_dss_t0=$(_ds_now_ns)
	_ds_stage_start "$issue_number" "$repo_slug" "disk_space" "$_dss_t0" _ds_stage_attempt_id
	local _capacity_rc=0
	local _capacity_path="${AIDEVOPS_WORKTREE_BASE_DIR:-$HOME}"
	aidevops_worktree_capacity_check "$_capacity_path" || _capacity_rc=$?
	if [[ "$_capacity_rc" -ne 0 ]]; then
		if _dispatch_cleanup_disk_pressure "$issue_number" "$repo_slug" "$_capacity_path" \
			"${AIDEVOPS_DISK_CAPACITY_REASON}" "${AIDEVOPS_DISK_CAPACITY_AVAILABLE_KB}" \
			"${AIDEVOPS_DISK_CAPACITY_AVAILABLE_PERCENT}"; then
			:
		else
			echo "[dispatch_with_dedup] Dispatch blocked for #${issue_number} in ${repo_slug}: disk space critical (reason=${AIDEVOPS_DISK_CAPACITY_REASON}, available=${AIDEVOPS_DISK_CAPACITY_AVAILABLE_KB}KB/${AIDEVOPS_DISK_CAPACITY_AVAILABLE_PERCENT}%, require at least ${AIDEVOPS_MIN_WORKTREE_FREE_KB:-5242880}KB and ${AIDEVOPS_MIN_WORKTREE_FREE_PERCENT:-5}%). Run: worktree-helper.sh clean --auto --force-merged" >>"$LOGFILE"
			_ds_record "$issue_number" "$repo_slug" "dedup.disk_space" "$_dss_t0"
			return 1
		fi
	fi
	_ds_record "$issue_number" "$repo_slug" "dedup.disk_space" "$_dss_t0"

	# GH#18987: Worktree count cap — refuse dispatch when the repo has 200+
	# registered git worktrees. At that scale, new worktrees risk consuming
	# tens of GB; stale merged ones should be cleaned before adding more.
	_dss_t0=$(_ds_now_ns)
	_ds_stage_start "$issue_number" "$repo_slug" "worktree_cap" "$_dss_t0" _ds_stage_attempt_id
	local _wt_max=""
	_wt_max="${AIDEVOPS_MAX_WORKTREES:-200}"
	[[ "$_wt_max" =~ ^[1-9][0-9]*$ ]] || _wt_max=200
	if ! _dispatch_worktree_capacity_gate "$repo_path" "$issue_number" "$repo_slug" "$_wt_max"; then
		echo "[dispatch_with_dedup] Dispatch blocked for #${issue_number} in ${repo_slug}: worktree capacity remains unavailable after bounded guarded cleanup" >>"$LOGFILE"
		_ds_record "$issue_number" "$repo_slug" "dedup.worktree_cap" "$_dss_t0"
		return 1
	fi
	_ds_record "$issue_number" "$repo_slug" "dedup.worktree_cap" "$_dss_t0"
	return 0
}

_dispatch_dedup_state_label_gates() {
	local issue_number="$1" repo_slug="$2" issue_meta_json="$3"
	local _dss_t0="" _ds_stage_attempt_id="" target_state=""
	# REST fallback returns lowercase state while GraphQL returns uppercase.
	target_state=$(printf '%s' "$issue_meta_json" | jq -r '.state // ""' 2>/dev/null | tr '[:lower:]' '[:upper:]')

	_dss_t0=$(_ds_now_ns)
	_ds_stage_start "$issue_number" "$repo_slug" "state_check" "$_dss_t0" _ds_stage_attempt_id
	if [[ "$target_state" != "$_PULSE_DISPATCH_OPEN_STATE" ]]; then
		echo "[dispatch_with_dedup] Dispatch blocked for #${issue_number} in ${repo_slug}: issue state is ${target_state:-unknown}" >>"$LOGFILE"
		_ds_record "$issue_number" "$repo_slug" "dedup.state_check" "$_dss_t0"
		return 1
	fi
	_ds_record "$issue_number" "$repo_slug" "dedup.state_check" "$_dss_t0"

	# publication:pending is an unconditional hold while canonical planning is
	# absent from the default branch. It is checked here as defence-in-depth
	# before direct-dispatch paths can claim or launch a worker.
	_dss_t0=$(_ds_now_ns)
	_ds_stage_start "$issue_number" "$repo_slug" "publication_pending" "$_dss_t0" _ds_stage_attempt_id
	if _has_publication_pending_label "$issue_meta_json"; then
		echo "[dispatch_with_dedup] Dispatch blocked for #${issue_number} in ${repo_slug}: publication:pending label present" >>"$LOGFILE"
		_ds_record "$issue_number" "$repo_slug" "dedup.publication_pending" "$_dss_t0"
		return 1
	fi
	_ds_record "$issue_number" "$repo_slug" "dedup.publication_pending" "$_dss_t0"

	# GH#20219: parent-task / meta added here as defence-in-depth. The
	# canonical parent-task guard is in dispatch-dedup-helper.sh Layer 6
	# (_is_assigned_check_parent_task), but adding it to the early management-
	# label block ensures it fires even if Layer 6 is somehow bypassed (e.g.
	# dedup_helper missing, jq failure in the helper, or a direct-dispatch
	# code path that skips check_dispatch_dedup). This closes Factor 1 of
	# the #20161 incident where a parent-task issue was dispatched despite
	# the label being continuously present.
	_dss_t0=$(_ds_now_ns)
	_ds_stage_start "$issue_number" "$repo_slug" "mgmt_label" "$_dss_t0" _ds_stage_attempt_id
	if _has_consolidated_label "$issue_meta_json"; then
		echo "[dispatch_with_dedup] Dispatch blocked for #${issue_number} in ${repo_slug}: consolidated issue label present (GH#23187)" >>"$LOGFILE"
		_ds_record "$issue_number" "$repo_slug" "dedup.mgmt_label" "$_dss_t0"
		return 1
	fi
	_ds_record "$issue_number" "$repo_slug" "dedup.mgmt_label" "$_dss_t0"

	_dss_t0=$(_ds_now_ns)
	_ds_stage_start "$issue_number" "$repo_slug" "label_checks" "$_dss_t0" _ds_stage_attempt_id
	if printf '%s' "$issue_meta_json" | jq -e '.labels | map(.name) | index("status:needs-info")' >/dev/null 2>&1; then
		echo "[dispatch_with_dedup] NEEDS_INFO_BLOCKED for #${issue_number} in ${repo_slug}: status:needs-info label present" >>"$LOGFILE"
		_ds_record "$issue_number" "$repo_slug" "$_PULSE_DISPATCH_DEDUP_LABEL_CHECK_STAGE" "$_dss_t0"
		return 1
	fi
	if printf '%s' "$issue_meta_json" | jq -e '.labels | map(.name) | (index("supervisor") or index("contributor") or index("persistent") or index("quality-review") or index("on hold") or index("blocked") or index("parent-task") or index("meta"))' >/dev/null 2>&1; then
		echo "[dispatch_with_dedup] Dispatch blocked for #${issue_number} in ${repo_slug}: non-dispatchable management label present" >>"$LOGFILE"
		_ds_record "$issue_number" "$repo_slug" "$_PULSE_DISPATCH_DEDUP_LABEL_CHECK_STAGE" "$_dss_t0"
		return 1
	fi

	# t2424/GH#20030: resolved-status label check (defence-in-depth alongside eligibility gate).
	# status:done and status:resolved signal already-completed work. Checking here (in the
	# dedup layers) catches these before the more expensive eligibility check fires.
	if printf '%s' "$issue_meta_json" | jq -e '.labels | map(.name) | (index("status:done") or index("status:resolved"))' >/dev/null 2>&1; then
		echo "[dispatch_with_dedup] Dispatch blocked for #${issue_number} in ${repo_slug}: status:done or status:resolved label present (t2424)" >>"$LOGFILE"
		_ds_record "$issue_number" "$repo_slug" "$_PULSE_DISPATCH_DEDUP_LABEL_CHECK_STAGE" "$_dss_t0"
		return 1
	fi
	_ds_record "$issue_number" "$repo_slug" "$_PULSE_DISPATCH_DEDUP_LABEL_CHECK_STAGE" "$_dss_t0"

	# t1894/GH#18648: Cryptographic approval gate (ever-NMR) with
	# review-followup exemption for bot-generated cleanup issues.
	_dss_t0=$(_ds_now_ns)
	_ds_stage_start "$issue_number" "$repo_slug" "nmr_gate" "$_dss_t0" _ds_stage_attempt_id
	if _check_nmr_approval_gate "$issue_number" "$repo_slug" "$issue_meta_json"; then
		_ds_record "$issue_number" "$repo_slug" "dedup.nmr_gate" "$_dss_t0"
		return 1
	fi
	_ds_record "$issue_number" "$repo_slug" "dedup.nmr_gate" "$_dss_t0"
	return 0
}

_dispatch_dedup_dependency_gates() {
	local issue_number="$1" repo_slug="$2" repo_path="$3" issue_meta_json="$4"
	local _dss_t0="" _ds_stage_attempt_id="" target_title=""
	target_title=$(printf '%s' "$issue_meta_json" | jq -r '.title // ""' 2>/dev/null)

	if [[ "$target_title" == \[Supervisor:* ]]; then
		echo "[dispatch_with_dedup] Dispatch blocked for #${issue_number} in ${repo_slug}: supervisor telemetry title" >>"$LOGFILE"
		return 1
	fi

	# t3040: commit-subject dedup gate REMOVED from dispatch hot path
	# (cost 100-156s/candidate). Workers do their own t2046 duplicate
	# discovery; helpers retained for diagnostic use. Regression guard:
	# tests/test-pulse-dispatch-core-t3040-gate-removed.sh.

	# t1927/GH#23932: Blocked-by enforcement — skip dispatch if a dependency is unresolved.
	# Checks GitHub's native blockedBy relationship field first, then falls back
	# to issue-body markers such as "blocked-by:tNNN" or "Blocked by #NNN".
	# t2996: body now travels in $issue_meta_json (`,body` was added at the
	# canonical gh call), so no gate re-fetches it.
	_dss_t0=$(_ds_now_ns)
	_ds_stage_start "$issue_number" "$repo_slug" "blocked_by" "$_dss_t0" _ds_stage_attempt_id
	local _dispatch_issue_body
	_dispatch_issue_body=$(printf '%s' "$issue_meta_json" | jq -r '.body // ""' 2>/dev/null) || _dispatch_issue_body=""
	if _dedup_dependabot_intake_target "$issue_number" "$repo_slug" "$_dispatch_issue_body" "$issue_meta_json"; then
		# GH#32979: owned = another intake legitimately holds the target
		# (benign); anything else is a fail-closed read or evidence failure.
		local _dependabot_reason="dependabot_target_unverified"
		[[ "${_DEDUP_DEPENDABOT_BLOCK:-}" == "owned" ]] && _dependabot_reason="dependabot_target_owned"
		echo "[dispatch_with_dedup] DISPATCH_BLOCK_REASON reason=${_dependabot_reason} signal=dependabot_target_${_DEDUP_DEPENDABOT_BLOCK:-unknown} issue=#${issue_number} repo=${repo_slug}" >>"$LOGFILE"
		_ds_record "$issue_number" "$repo_slug" "dedup.dependabot_target" "$_dss_t0"
		return 1
	fi
	if is_blocked_by_unresolved "$_dispatch_issue_body" "$repo_slug" "$issue_number"; then
		echo "[dispatch_with_dedup] Dispatch blocked for #${issue_number} in ${repo_slug}: unresolved blocked-by dependency (t1927)" >>"$LOGFILE"
		_ds_record "$issue_number" "$repo_slug" "dedup.blocked_by" "$_dss_t0"
		return 1
	fi
	_ds_record "$issue_number" "$repo_slug" "dedup.blocked_by" "$_dss_t0"
	return 0
}

# t18505/GH#32729: costly scope gates run only after the read-only dedup
# layers confirm no other owner, PR or terminal-blocker circuit. Measured on
# a live runner, ~75% of candidates reaching these gates were rejected by the
# dedup layers anyway, so running them first spent ~7h/day of candidate
# evaluation (consolidation p50 16.5s) and could fire consolidation or
# simplification side effects for issues another runner owns.
_dispatch_dedup_scope_gates() {
	local issue_number="$1" repo_slug="$2" repo_path="$3" issue_meta_json="$4"
	local _dss_t0="" _ds_stage_attempt_id="" _dispatch_issue_body=""
	_dispatch_issue_body=$(printf '%s' "$issue_meta_json" | jq -r '.body // ""' 2>/dev/null) || _dispatch_issue_body=""

	# Pre-dispatch: issue consolidation check. If an issue has accumulated
	# multiple substantive comments that change scope (not dispatch/approval
	# machinery), dispatch a consolidation worker first to merge everything
	# into a clean issue body. This prevents implementing workers from spending
	# tokens reconstructing scope from comment archaeology.
	# t2996: pass meta_json through so the consolidation helper skips its
	# `gh issue view --json labels` call (label CSV derived from JSON instead).
	_dss_t0=$(_ds_now_ns)
	_ds_stage_start "$issue_number" "$repo_slug" "consolidation" "$_dss_t0" _ds_stage_attempt_id
	if _issue_needs_consolidation "$issue_number" "$repo_slug" "$issue_meta_json"; then
		_dispatch_issue_consolidation "$issue_number" "$repo_slug" "$repo_path"
		echo "[dispatch_with_dedup] Dispatch deferred for #${issue_number} in ${repo_slug}: issue needs comment consolidation" >>"$LOGFILE"
		_ds_record "$issue_number" "$repo_slug" "dedup.consolidation" "$_dss_t0"
		return 1
	fi
	_ds_record "$issue_number" "$repo_slug" "dedup.consolidation" "$_dss_t0"

	# Pre-dispatch: large-file simplification gate. If the issue body
	# references files that exceed LARGE_FILE_LINE_THRESHOLD, create a
	# blocked-by simplification task instead of dispatching. Workers
	# shouldn't pay the complexity tax of navigating a 12,000-line file.
	# t2996: pass meta_json through so the gate skips its `gh issue view --json
	# labels` AND `--json title` calls (both derived from the bundled JSON).
	_dss_t0=$(_ds_now_ns)
	_ds_stage_start "$issue_number" "$repo_slug" "large_file" "$_dss_t0" _ds_stage_attempt_id
	if _issue_targets_large_files "$issue_number" "$repo_slug" "$_dispatch_issue_body" "$repo_path" "" "$issue_meta_json"; then
		echo "[dispatch_with_dedup] Dispatch deferred for #${issue_number} in ${repo_slug}: targets large file(s), simplification gate" >>"$LOGFILE"
		_ds_record "$issue_number" "$repo_slug" "dedup.large_file" "$_dss_t0"
		return 1
	fi
	_ds_record "$issue_number" "$repo_slug" "dedup.large_file" "$_dss_t0"

	# t2117/GH#19109: File-footprint overlap throttle. If another in-flight
	# worker is already modifying the same files, defer this dispatch to
	# prevent CONFLICTING cascades. The check is cheap (cached per repo per
	# cycle) and decays naturally when the blocking issue's status labels clear.
	_dss_t0=$(_ds_now_ns)
	_ds_stage_start "$issue_number" "$repo_slug" "footprint" "$_dss_t0" _ds_stage_attempt_id
	local _footprint_signal=""
	_footprint_signal=$(_footprint_check_overlap "$issue_number" "$repo_slug" "$_dispatch_issue_body" 2>/dev/null) || true
	if [[ -n "$_footprint_signal" ]]; then
		echo "[dispatch_with_dedup] (t2117) Dispatch deferred for #${issue_number} in ${repo_slug}: ${_footprint_signal}" >>"$LOGFILE"
		_ds_record "$issue_number" "$repo_slug" "dedup.footprint" "$_dss_t0"
		return 1
	fi
	_ds_record "$issue_number" "$repo_slug" "dedup.footprint" "$_dss_t0"
	return 0
}

_dispatch_dedup_check_layers() {
	local issue_number="$1" repo_slug="$2" dispatch_title="$3" issue_title="$4"
	local self_login="$5" repo_path="$6" issue_meta_json="$7"
	local _dss_t0="" _ds_stage_attempt_id="" gate_rc=0
	_dispatch_dedup_capacity_gates "$issue_number" "$repo_slug" "$issue_title" \
		"$self_login" "$repo_path" "$issue_meta_json" || gate_rc=$?
	[[ "$gate_rc" -eq 0 ]] || return "$gate_rc"
	_dispatch_dedup_state_label_gates "$issue_number" "$repo_slug" "$issue_meta_json" || gate_rc=$?
	[[ "$gate_rc" -eq 0 ]] || return "$gate_rc"
	_dispatch_dedup_dependency_gates "$issue_number" "$repo_slug" "$repo_path" "$issue_meta_json" || gate_rc=$?
	[[ "$gate_rc" -eq 0 ]] || return "$gate_rc"

	# Read-only dedup layers — cannot be skipped.
	# t2996: ISSUE_META_JSON forwards the canonical bundle to
	# dispatch-dedup-helper.sh (Layer 6 `is-assigned`, Layer 4 `has-open-pr`,
	# etc.). The helper's t-prefixed lookup paths already detect the env var
	# (see dispatch-dedup-helper.sh:898-900) and skip their own
	# `gh issue view --json labels,assignees` call when present. Without this
	# export, those layers re-fetch the same JSON we just bundled — wasting
	# 1-2 more gh calls under load.
	_dss_t0=$(_ds_now_ns)
	_ds_stage_start "$issue_number" "$repo_slug" "7_layers" "$_dss_t0" _ds_stage_attempt_id
	local _dedup_rc=0
	local _dedup_signal=""
	_dedup_signal=$(ISSUE_META_JSON="$issue_meta_json" DISPATCH_REPO_PATH="$repo_path" \
		check_dispatch_dedup "$issue_number" "$repo_slug" "$dispatch_title" "$issue_title" "$self_login") || _dedup_rc=$?
	if [[ "$_dedup_rc" -eq 0 || "$_dedup_rc" -eq 3 ]]; then
		local _dedup_block_signal="dedup_guard_blocked"
		local _dedup_block_reason="dedup_active_claim"
		if [[ -n "$_dedup_signal" ]]; then
			_dedup_block_signal="${_dedup_signal%%$'\n'*}"
			local _dedup_helper_path="${SCRIPT_DIR:-${BASH_SOURCE[0]%/*}}/dispatch-dedup-helper.sh"
			_dedup_block_reason=$("$_dedup_helper_path" classify-blocker "$_dedup_block_signal") || _dedup_block_reason="dedup_active_claim"
		fi
		echo "[dispatch_with_dedup] DISPATCH_BLOCK_REASON reason=${_dedup_block_reason} signal=${_dedup_block_signal} issue=#${issue_number} repo=${repo_slug}" >>"$LOGFILE"
		echo "[dispatch_with_dedup] Dedup guard blocked #${issue_number} in ${repo_slug}" >>"$LOGFILE"
		_ds_record "$issue_number" "$repo_slug" "dedup.7_layers" "$_dss_t0"
		if [[ "$_dedup_rc" -eq 3 ]]; then
			return 3
		fi
		return 1
	fi
	_ds_record "$issue_number" "$repo_slug" "dedup.7_layers" "$_dss_t0"

	_dispatch_dedup_scope_gates "$issue_number" "$repo_slug" "$repo_path" "$issue_meta_json" || gate_rc=$?
	[[ "$gate_rc" -eq 0 ]] || return "$gate_rc"

	# GH#22399/GH#31404: fail closed before launch, but only after dedup
	# confirms eligibility. Never mutate author-gate labels on an active PR.
	_dss_t0=$(_ds_now_ns)
	_ds_stage_start "$issue_number" "$repo_slug" "external_author_gate" "$_dss_t0" _ds_stage_attempt_id
	if _check_external_issue_author_gate "$issue_number" "$repo_slug"; then
		_ds_record "$issue_number" "$repo_slug" "dedup.external_author_gate" "$_dss_t0"
		return 1
	fi
	_ds_record "$issue_number" "$repo_slug" "dedup.external_author_gate" "$_dss_t0"

	return 0
}

#######################################
# t2424/GH#20030: Run the generic pre-dispatch eligibility gate and
# translate its exit codes into a simple 0=proceed, 1=abort contract
# for dispatch_with_dedup. Keeps dispatch_with_dedup short.
#
# Gate exit codes (from _run_predispatch_eligibility_check):
#   0  — eligible; proceed
#   2  — CLOSED state; abort
#   3  — status:done/resolved label; abort
#   4  — linked PR merged in recent window; abort
#   5  — recent closing commit on default branch; abort
#   6  — parent-task or meta label; abort (GH#20219)
#   20 — gh API error; fail-open (proceed with warning)
#
# Args:
#   $1 - issue_number
#   $2 - repo_slug
#   $3 - issue_meta_json (pre-fetched; forwarded via ISSUE_META_JSON to avoid duplicate gh calls)
#
# Exit codes:
#   0 — dispatch should proceed
#   1 — dispatch aborted (gate found issue ineligible)
#######################################
_run_eligibility_gate_or_abort() {
	local issue_number="$1"
	local repo_slug="$2"
	local issue_meta_json="$3"

	local rc=0
	ISSUE_META_JSON="$issue_meta_json" \
		_run_predispatch_eligibility_check "$issue_number" "$repo_slug" || rc=$?

	if [[ "$rc" -ne 0 && "$rc" -ne 20 ]]; then
		echo "[dispatch_with_dedup] t2424: Pre-dispatch eligibility gate aborted #${issue_number} in ${repo_slug} (rc=${rc}) — not dispatching" >>"$LOGFILE"
		return 1
	fi
	if [[ "$rc" -eq 20 ]]; then
		echo "[dispatch_with_dedup] t2424: Eligibility gate API error for #${issue_number} (rc=20) — fail-open, proceeding" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# Verify and roll back queued ownership created by this exact pre-launch claim.
# The claim comment remains present while this runs, providing a lease identity
# that prevents an older abort from clearing a newer dispatch attempt.
# Args: issue number, repo slug, runner login, claim comment id
# Returns: 0 when ownership is absent or verified rolled back; 1 on uncertainty.
#######################################
_rollback_prelaunch_ownership() {
	local issue_number="$1"
	local repo_slug="$2"
	local self_login="$3"
	local claim_comment_id="$4"
	local comments_endpoint="repos/${repo_slug}/issues/${issue_number}/comments?per_page=100"
	local comments_json=""
	local latest_claim_id=""

	comments_json=$(gh api "$comments_endpoint" --paginate --slurp 2>/dev/null) || return 1
	# #aidevops:trust-boundary — anchor the rollback fence to GitHub's
	# authenticated comment author. Body text and bare association values cannot
	# let an external commenter supersede this runner's exact claim.
	latest_claim_id=$(printf '%s' "$comments_json" | jq -r --arg self "$self_login" '
		flatten(1)
		| [.[] | select(
			((.user.login // .author.login // "") | ascii_downcase) == ($self | ascii_downcase)
			and ((.body // "") | contains("DISPATCH_CLAIM nonce="))
		)]
		| last | (.id // "")
	' 2>/dev/null) || return 1
	if [[ -z "$latest_claim_id" || "$latest_claim_id" != "$claim_comment_id" ]]; then
		echo "[dispatch_with_dedup] Pre-launch rollback skipped for #${issue_number}: claim ${claim_comment_id} is no longer current (latest=${latest_claim_id:-unknown})" >>"$LOGFILE"
		return 1
	fi

	local issue_meta_json=""
	issue_meta_json=$(gh_issue_view "$issue_number" --repo "$repo_slug" \
		--json state,labels,assignees,locked 2>/dev/null) || return 1
	local owns_queued=""
	owns_queued=$(printf '%s' "$issue_meta_json" | jq -r --arg self "$self_login" --arg open_state "$_PULSE_DISPATCH_OPEN_STATE" '
		(.state == $open_state) and
		(([.labels[].name] | index("status:queued")) != null) and
		(([.assignees[].login] | index($self)) != null)
	' 2>/dev/null) || return 1
	[[ "$owns_queued" == "true" ]] || return 0

	if ! set_issue_status "$issue_number" "$repo_slug" "available" \
		--remove-assignee "$self_login" >/dev/null 2>&1; then
		echo "[dispatch_with_dedup] Pre-launch rollback failed for #${issue_number}: unable to restore available ownership" >>"$LOGFILE"
		return 1
	fi
	if declare -F unlock_issue_after_worker >/dev/null 2>&1; then
		unlock_issue_after_worker "$issue_number" "$repo_slug" || return 1
	fi

	issue_meta_json=$(gh_issue_view "$issue_number" --repo "$repo_slug" \
		--json state,labels,assignees,locked 2>/dev/null) || return 1
	local final_labels=""
	final_labels=$(printf '%s' "$issue_meta_json" | jq -r '[.labels[]?.name] | join(",")' 2>/dev/null) || return 1
	local expected_locked=false
	local lock_summary="issue unlocked"
	if _auto_dispatch_lock_required "$final_labels"; then
		expected_locked=true
		lock_summary="required conversation lock retained"
	fi
	if ! printf '%s' "$issue_meta_json" | jq -e --arg self "$self_login" --arg open_state "$_PULSE_DISPATCH_OPEN_STATE" '
		.state == $open_state and
		(([.labels[].name] | index("status:queued")) == null) and
		(([.labels[].name] | index("status:available")) != null) and
		(([.assignees[].login] | index($self)) == null)
	' >/dev/null 2>&1 ||
		! printf '%s' "$issue_meta_json" | jq -e --argjson expected_locked "$expected_locked" '
		.locked == $expected_locked
	' >/dev/null 2>&1; then
		echo "[dispatch_with_dedup] Pre-launch rollback verification failed for #${issue_number}; retaining claim for stale recovery" >>"$LOGFILE"
		return 1
	fi

	echo "[dispatch_with_dedup] Pre-launch rollback verified for #${issue_number}: queued ownership removed and ${lock_summary}" >>"$LOGFILE"
	return 0
}

#######################################
# Release a dispatch claim when a post-claim pre-launch step aborts.
#
# dispatch-claim-helper.sh posts DISPATCH_CLAIM before later gates and launch
# sub-stages run. When those later steps abort before the worker wrapper starts,
# neither the worker EXIT trap nor _dlw_post_launch_hooks can emit lifecycle
# evidence. Post CLAIM_RELEASED here so peer runners see a terminal marker and
# the issue thread records why no worker comment appeared.
#
# Args:
#   $1 - issue_number
#   $2 - repo_slug
#   $3 - self_login
#   $4 - reason suffix for dispatch_aborted:<reason>
#######################################
_release_dispatch_claim_on_abort() {
	local issue_number="$1"
	local repo_slug="$2"
	local self_login="$3"
	local reason="$4"

	[[ -n "${_claim_comment_id:-}" ]] || return 0
	[[ -n "$issue_number" && -n "$repo_slug" ]] || return 0
	[[ -n "$self_login" ]] || self_login="$(whoami 2>/dev/null || printf '%s' unknown)"
	case "$reason" in
	*[^A-Za-z0-9_.:-]* | "") reason="unknown" ;;
	esac

	# t3549 (GH#22615): for pre-launch aborts where the worker never
	# started (canary preflight fail, eligibility gate, predispatch
	# validator close, worktree precreation fail), the claim comment is
	# noise — no audit trail value (no worker existed) and the issue
	# thread accumulates 89+ DISPATCH_CLAIM/CLAIM_RELEASED pairs over a
	# canary-failure storm. DELETE the original claim instead of posting a
	# release receipt. The negative cache (90s timeout / 300s overload)
	# carries the dedup signal locally; cross-runner dedup loses the lock
	# but the next runner will face the same canary failure and back off
	# the same way. For any other abort reason the legacy CLAIM_RELEASED
	# audit comment is preserved.
	local _is_pre_launch_abort=0
	case "$reason" in
	worker_launch_rc_* | predispatch_validator_closed | eligibility_gate)
		_is_pre_launch_abort=1
		;;
	esac

	if [[ "$_is_pre_launch_abort" == "1" ]]; then
		if [[ "$reason" == worker_launch_rc_* ]] &&
			! _rollback_prelaunch_ownership "$issue_number" "$repo_slug" "$self_login" "$_claim_comment_id"; then
			echo "[dispatch_with_dedup] Retaining dispatch claim ${_claim_comment_id} after uncertain pre-launch rollback for #${issue_number} (${reason})" >>"$LOGFILE"
			return 1
		fi
		local _claim_helper="${SCRIPT_DIR}/dispatch-claim-helper.sh"
		if [[ -x "$_claim_helper" ]]; then
			# Use the helper's _delete_comment if exposed via subcommand,
			# otherwise fall back to a direct gh api DELETE.
			gh api "repos/${repo_slug}/issues/comments/${_claim_comment_id}" \
				--method DELETE >/dev/null 2>>"$LOGFILE" || {
				echo "[dispatch_with_dedup] Warning: failed to delete dispatch claim ${_claim_comment_id} on pre-launch abort #${issue_number} (${reason})" >>"$LOGFILE"
			}
		else
			gh api "repos/${repo_slug}/issues/comments/${_claim_comment_id}" \
				--method DELETE >/dev/null 2>>"$LOGFILE" || true
		fi
		echo "[dispatch_with_dedup] Deleted dispatch claim ${_claim_comment_id} for pre-launch abort #${issue_number} (${reason}) — no worker started, audit trail noise eliminated (t3549)" >>"$LOGFILE"
		_claim_comment_id=""
		return 0
	fi

	# The claim producer uses its nonce as the lease token. Retire only this
	# captured generation; a delayed abort must not release a peer's newer claim.
	local claim_nonce="${_claim_lease_token:-}"
	if [[ ! "$_claim_comment_id" =~ ^[1-9][0-9]*$ || ! "$claim_nonce" =~ ^[A-Za-z0-9_-]+$ ]]; then
		echo "[dispatch_with_dedup] Retaining claim on #${issue_number}: abort generation identity unavailable" >>"$LOGFILE"
		return 1
	fi
	local body
	local aidevops_version="$AIDEVOPS_UNKNOWN_VERSION" opencode_version="$AIDEVOPS_UNKNOWN_VERSION"
	if declare -F aidevops_find_version >/dev/null 2>&1; then
		aidevops_version=$(aidevops_find_version 2>/dev/null || printf '%s' "$AIDEVOPS_UNKNOWN_VERSION")
	fi
	if declare -F _detect_opencode_version >/dev/null 2>&1; then
		opencode_version=$(_detect_opencode_version 2>/dev/null || printf '%s' "")
		opencode_version="${opencode_version:-$AIDEVOPS_UNKNOWN_VERSION}"
	fi
	body="<!-- ops:start — workers: skip this comment, it is audit trail not implementation context -->
CLAIM_RELEASED reason=dispatch_aborted:${reason} runner=${self_login} ts=$(date -u +%Y-%m-%dT%H:%M:%SZ) claim_id=${_claim_comment_id} nonce=${claim_nonce} aidevops_version=${aidevops_version} opencode_version=${opencode_version}
<!-- ops:end -->"
	gh api "repos/${repo_slug}/issues/${issue_number}/comments" \
		--method POST \
		--field body="$body" \
		>/dev/null 2>>"$LOGFILE" || {
		echo "[dispatch_with_dedup] Warning: failed to release dispatch claim for aborted #${issue_number} (${reason})" >>"$LOGFILE"
	}
	echo "[dispatch_with_dedup] Released dispatch claim ${_claim_comment_id} for aborted #${issue_number} (${reason})" >>"$LOGFILE"
	_claim_comment_id=""
	return 0
}

#######################################
# Dispatch a worker for the given issue, guarded by all dedup and
# pre-dispatch safety layers. Thin orchestrator: delegates to
# _dispatch_dedup_check_layers (decision) and _dispatch_launch_worker
# (action). External signature is unchanged from the pre-t1999 version.
#
# Arguments:
#   $1 - issue_number
#   $2 - repo_slug (owner/repo)
#   $3 - dispatch_title (normalized title used as dedup key)
#   $4 - issue_title (raw issue title; optional, default empty)
#   $5 - self_login (dispatching runner login; optional, default empty)
#   $6 - repo_path (local path to the repo)
#   $7 - prompt (worker prompt string)
#   $8 - session_key (optional, default "issue-{issue_number}")
#   $9 - model_override (optional, default empty = ordered healthy auto-selection)
#
# Exit codes:
#   0 - worker dispatched successfully
#   1 - hard error (metadata unavailable, dedup gate blocked)
#   2 - explicit launch no-op (canary/precreate/orphan guard; retry later)
#######################################
_dispatch_load_and_validate_metadata() {
	local issue_number="$1" repo_slug="$2"
	local _ds_t0=""
	# issue_meta_json is owned by dispatch_with_dedup in the calling scope.
	# Do not shadow it: the fetched bundle is reused by all later gates.
	_ds_t0=$(_ds_now_ns)
	issue_meta_json=$(gh_issue_view "$issue_number" --repo "$repo_slug" \
		--json number,title,state,labels,assignees,body,author,createdAt 2>/dev/null) || issue_meta_json=""
	_ds_record "$issue_number" "$repo_slug" "gh_issue_view" "$_ds_t0"
	if [[ -z "$issue_meta_json" ]]; then
		echo "[dispatch_with_dedup] Dispatch blocked for #${issue_number} in ${repo_slug}: unable to load issue metadata" >>"$LOGFILE"
		return 1
	fi
	local issue_state
	issue_state=$(printf '%s' "$issue_meta_json" | jq -r '.state // ""' 2>/dev/null | tr '[:lower:]' '[:upper:]') || issue_state=""
	if [[ "$issue_state" == "CLOSED" ]]; then
		echo "[dispatch] Skipping #${issue_number}: state=CLOSED" >>"$LOGFILE"
		pulse-batch-prefetch-helper.sh evict-issue "$repo_slug" "$issue_number" 2>/dev/null || true
		return 1
	fi

	#aidevops:trust-boundary -- a worker permission request is dispatchable only
	# after the request-specific signed grant flow removes its dedicated label.
	if _dispatch_waiting_for_maintainer_permission "$issue_meta_json"; then
		echo "[dispatch_with_dedup] Dispatch blocked for #${issue_number} in ${repo_slug}: waiting for a scoped signed maintainer permission grant" >>"$LOGFILE"
		echo "[dispatch_with_dedup] DISPATCH_BLOCK_REASON reason=needs_maintainer_permissions signal=needs-maintainer-permissions issue=#${issue_number} repo=${repo_slug}" >>"$LOGFILE"
		return 1
	fi
	if _dispatch_permission_history_requires_grant "$issue_number" "$repo_slug"; then
		echo "[dispatch_with_dedup] Dispatch blocked for #${issue_number} in ${repo_slug}: permission-request history lacks a current matching signed grant (${_DISPATCH_PERMISSION_VERIFY_RESULT:-unknown})" >>"$LOGFILE"
		echo "[dispatch_with_dedup] DISPATCH_BLOCK_REASON reason=permission_grant_unverified signal=${_DISPATCH_PERMISSION_VERIFY_RESULT:-unknown} issue=#${issue_number} repo=${repo_slug}" >>"$LOGFILE"
		return 1
	fi

	# A PR shares the Issues API number space but must never be dispatched.
	local _target_pr_rc=0
	_dispatch_target_is_pull_request "$issue_number" "$repo_slug" || _target_pr_rc=$?
	if [[ "$_target_pr_rc" -eq 0 ]]; then
		echo "[dispatch_with_dedup] Dispatch blocked for #${issue_number} in ${repo_slug}: target is a pull request, not a dispatchable issue (GH#22948)" >>"$LOGFILE"
		echo "[dispatch_with_dedup] DISPATCH_BLOCK_REASON reason=pr_target_not_dispatchable signal=pr_target_not_dispatchable issue=#${issue_number} repo=${repo_slug}" >>"$LOGFILE"
		return 3
	fi
	if [[ "$_target_pr_rc" -ne 1 ]]; then
		echo "[dispatch_with_dedup] Dispatch blocked for #${issue_number} in ${repo_slug}: unable to verify target is not a pull request (GH#22948, rc=${_target_pr_rc})" >>"$LOGFILE"
		return 1
	fi
	if _is_renovate_dependency_dashboard_issue "$issue_meta_json"; then
		echo "[dispatch_with_dedup] Dispatch blocked for #${issue_number} in ${repo_slug}: Renovate Dependency Dashboard issues are metadata only" >>"$LOGFILE"
		echo "[dispatch_with_dedup] DISPATCH_BLOCK_REASON reason=renovate_dependency_dashboard signal=renovate_dependency_dashboard issue=#${issue_number} repo=${repo_slug}" >>"$LOGFILE"
		return 3
	fi
	return 0
}

# Stable identity of the brief body that produced a scope hold. Other pulse
# paths (and other runners) can move status:blocked back to available, so the
# label alone cannot prove the brief owner was already told (GH#32531).
_dispatch_brief_hold_body_hash() {
	local issue_body="$1"
	local digest=""
	if command -v shasum >/dev/null 2>&1; then
		digest=$(printf '%s' "$issue_body" | shasum -a 256 2>/dev/null | cut -c1-24) || digest=""
	elif command -v sha256sum >/dev/null 2>&1; then
		digest=$(printf '%s' "$issue_body" | sha256sum 2>/dev/null | cut -c1-24) || digest=""
	fi
	[[ "$digest" =~ ^[a-f0-9]{24}$ ]] || return 1
	printf '%s\n' "$digest"
	return 0
}

# Returns 0 when a trusted comment already records the hold for this exact
# body, 1 when none exists, 2 when comments cannot be read. A forged marker can
# only suppress a duplicate comment; the blocked label is still applied.
_dispatch_brief_hold_recorded() {
	local issue_number="$1" repo_slug="$2" marker="$3"
	local comments_json="" state=""
	comments_json=$(gh api "repos/${repo_slug}/issues/${issue_number}/comments?per_page=100" \
		--paginate --slurp 2>/dev/null) || return 2
	# Non-array payloads produce no output and are treated as unreadable.
	state=$(printf '%s' "$comments_json" | jq -r --arg marker "$marker" '
		arrays
		| (if ([.[0]? | arrays] | length) > 0 then add else . end)
		| if any(.[]?; ((.author_association // "") | IN("OWNER", "MEMBER", "COLLABORATOR"))
			and ((.body // "") | contains($marker))) then "recorded" else "absent" end
	' 2>/dev/null) || return 2
	case "$state" in
	recorded) return 0 ;;
	absent) return 1 ;;
	esac
	return 2
}

# Fail before dedup posts a claim. The blocked label is the durable cycle gate;
# the body-hash marker keeps the brief-owner action to one comment per body even
# when the label is later cleared without a body change.
# GH#32979: every rc=1 logs exactly one DISPATCH_BLOCK_REASON naming the step
# (recorded as the _brief_scope_block breadcrumb), so blocked candidates are
# never metered as no_recent_log_evidence and untrusted unscoped briefs stay
# visible instead of retrying silently every cycle.
_dispatch_preclaim_brief_scope() {
	local issue_number="$1" repo_slug="$2" issue_meta_json="$3"
	local _brief_scope_block="" verdict_rc=0
	_dispatch_preclaim_brief_scope_verdict "$issue_number" "$repo_slug" "$issue_meta_json" || verdict_rc=$?
	[[ "$verdict_rc" -eq 0 ]] && return 0
	_brief_scope_log_block "$issue_number" "$repo_slug" "${_brief_scope_block:-unknown}"
	return 1
}

# Sets the caller's _brief_scope_block before each step that can return 1.
_dispatch_preclaim_brief_scope_verdict() {
	local issue_number="$1" repo_slug="$2" issue_meta_json="$3"
	local issue_body="" author="" comment_file="" scope_rc=0
	local body_hash="" hold_marker="" recorded_rc=0
	printf '%s' "$issue_meta_json" | jq -e '[.labels[]?.name] | index("auto-dispatch") != null' >/dev/null 2>&1 || return 0
	_brief_scope_block="status_blocked"
	if printf '%s' "$issue_meta_json" | jq -e '[.labels[]?.name] | index("status:blocked") != null' >/dev/null 2>&1; then
		return 1
	fi
	_brief_scope_block="body_unreadable"
	issue_body=$(printf '%s' "$issue_meta_json" | jq -r '.body // ""') || return 1
	"${SCRIPT_DIR}/pre-dispatch-validator-helper.sh" scope-check "$issue_number" "$issue_body" 1 >/dev/null 2>&1 || scope_rc=$?
	[[ "$scope_rc" -eq 0 ]] && return 0
	_brief_scope_block="validator_error"
	[[ "$scope_rc" -eq 40 ]] || return 1

	# aidevops:trust-boundary — only the authenticated runner may hold a trusted
	# implementation brief; untrusted authors must stay on the normal review path.
	_brief_scope_block="untrusted_author"
	author=$(printf '%s' "$issue_meta_json" | jq -r '.author.login // ""') || return 1
	_brief_scope_author_trusted "$repo_slug" "$author" || return 1
	# GH#32689: explicit Files to Modify declarations normalize to the exact
	# canonical scope; rewrite once and dispatch next cycle instead of holding.
	_brief_scope_block="self_heal_rewritten"
	if _dispatch_brief_scope_self_heal "$issue_number" "$repo_slug" "$issue_body"; then
		return 1
	fi
	_brief_scope_block="hold_marker_unavailable"
	body_hash=$(_dispatch_brief_hold_body_hash "$issue_body") || return 1
	hold_marker="<!-- aidevops:brief-hold reason=missing_files_scope body=${body_hash} -->"
	_dispatch_brief_hold_recorded "$issue_number" "$repo_slug" "$hold_marker" || recorded_rc=$?
	# Unreadable history: skip dispatch without writing; the next cycle retries.
	_brief_scope_block="history_unreadable"
	[[ "$recorded_rc" -eq 2 ]] && return 1
	if [[ "$recorded_rc" -eq 0 ]]; then
		_brief_scope_block="hold_recorded"
		set_issue_status "$issue_number" "$repo_slug" blocked >/dev/null || true
		echo "[dispatch_with_dedup] Brief hold for #${issue_number} in ${repo_slug} already recorded for this body; relabelled without a new comment" >>"${LOGFILE:-/dev/null}"
		return 1
	fi
	_brief_scope_block="hold_write_failed"
	comment_file=$(mktemp) || return 1
	aidevops_ops_marker brief-hold >"$comment_file" || return 1
	# shellcheck disable=SC2016 # literal Markdown backticks, not expansions
	printf '%s\nBrief hold: reason=missing_files_scope owner=brief-author.\nProjected state: status:blocked.\nNext action: Add a canonical ### Files Scope section with one `` - `repo/relative/path` `` line per permitted file (no prefix, nothing after the path) to the issue body, or explicit `` `EDIT: path` `` / `` `NEW: path` `` bullets under ### Files to Modify; verify with pre-dispatch-validator-helper.sh scope-check. The pulse releases this hold automatically once the edited body passes; no label change is needed. This body is not held again unless it changes.\n' "$hold_marker" >>"$comment_file"
	if ! set_issue_status "$issue_number" "$repo_slug" blocked >/dev/null; then
		rm -f "$comment_file"
		return 1
	fi
	if ! gh_issue_comment "$issue_number" --repo "$repo_slug" --body-file "$comment_file" >/dev/null; then
		rm -f "$comment_file"
		return 1
	fi
	rm -f "$comment_file"
	_brief_scope_block="hold_posted"
	return 1
}

dispatch_with_dedup() {
	local issue_number="$1"
	local repo_slug="$2"
	local dispatch_title="$3"
	local issue_title="${4:-}"
	local self_login="${5:-}"
	local repo_path="$6"
	local prompt="$7"
	local session_key="${8:-issue-${issue_number}}"
	local model_override="${9:-}"
	# GH#15317 fix: _claim_comment_id is set by check_dispatch_dedup() via
	# bash dynamic scoping, but must be declared in the calling function's
	# scope first. Without this, set -u crashes the wrapper on every dispatch,
	# SIGTERM-ing all active workers.
	local _claim_comment_id=""

	# GH#17503: Claim comments are NEVER deleted — they form the audit trail.
	# The _cleanup_claim_comment function is retained as a no-op for backward
	# compatibility (callers may still reference it on early-return paths).
	_cleanup_claim_comment() {
		# No-op: claim comments are persistent audit trail (GH#17503).
		# Previously deleted DISPATCH_CLAIM comments, which destroyed both
		# the lock and the audit trail — causing duplicate dispatches.
		return 0
	}

	# t3034: per-stage timing instrumentation — capture ceremony overhead.
	local _ds_ceremony_t0="" _ds_t0=""
	_ds_ceremony_t0=$(_ds_now_ns)

	# Hard stop for supervisor/telemetry issues (t1702 pulse guard).
	# The pulse prompt should already avoid these, but this deterministic
	# gate prevents dispatch when prompt fallback logic is too permissive.
	#
	# t2996: Single canonical gh call. Fetch number,title,state,labels,
	# assignees AND body in ONE request, then thread the bundle through every
	# downstream gate so they don't re-fetch. Replaces 4-5 redundant gh calls
	# (the old meta call + the blocked-by body fetch + the consolidation labels
	# fetch + the large-file labels/title fetches + the brief-freshness body
	# fetch) with a single call. See .agents/reference/dispatch-architecture.md
	# "gh API call budget" for the full inventory.
	local issue_meta_json="" metadata_rc=0
	_dispatch_load_and_validate_metadata "$issue_number" "$repo_slug" || metadata_rc=$?
	[[ "$metadata_rc" -eq 0 ]] || return "$metadata_rc"
	_dispatch_preclaim_brief_scope "$issue_number" "$repo_slug" "$issue_meta_json" || return 1

	# Run all pre-dispatch validation and dedup check layers (10 gates total).
	# Each gate logs its own blocked reason to LOGFILE before returning 1.
	# _claim_comment_id is set by check_dispatch_dedup inside this call via
	# bash dynamic scoping — accessible below because it was declared local above.
	_ds_t0=$(_ds_now_ns)
	local _dedup_check_rc=0
	_dispatch_dedup_check_layers \
		"$issue_number" "$repo_slug" "$dispatch_title" "$issue_title" \
		"$self_login" "$repo_path" "$issue_meta_json" || _dedup_check_rc=$?
	if [[ "$_dedup_check_rc" -ne 0 ]]; then
		_ds_record "$issue_number" "$repo_slug" "dedup_check" "$_ds_t0"
		if [[ "$_dedup_check_rc" -eq 3 ]]; then
			return 3
		fi
		return 1
	fi
	_ds_record "$issue_number" "$repo_slug" "dedup_check" "$_ds_t0"
	_dispatch_post_dedup_gates "$issue_number" "$repo_slug" "$repo_path" "$issue_title" "$self_login" || return $?
	_dispatch_launch_checked_worker "$issue_number" "$repo_slug" "$dispatch_title" "$issue_title" \
		"$self_login" "$repo_path" "$prompt" "$session_key" "$model_override"
	return $?
}

# Runs after dedup has established the claim. issue_meta_json and
# _claim_comment_id remain dynamically scoped to dispatch_with_dedup.
_dispatch_post_dedup_gates() {
	local issue_number="$1" repo_slug="$2" repo_path="$3" issue_title="$4" self_login="$5"
	local _ds_t0=""

	# t2063: brief-body freshness guard — defence-in-depth.
	# If a brief file exists for this issue but the issue body lacks the
	# `## Task Brief` or `## Worker Guidance` marker, force-enrich the body
	# so the worker sees inlined implementation context on first read. This
	# catches any legacy issue created via the pre-t2063 bare path, and
	# any future path that might bypass the primary fixes in claim-task-id.sh
	# and issue-sync-helper.sh. Non-fatal — dispatch proceeds even if enrich fails.
	# t2996: thread meta_json so the helper extracts body from JSON instead of
	# making a 5th `gh issue view --json body` call on the same candidate.
	_ds_t0=$(_ds_now_ns)
	_ensure_issue_body_has_brief "$issue_number" "$repo_slug" "$repo_path" "$issue_title" "$issue_meta_json"
	_ds_record "$issue_number" "$repo_slug" "brief_freshness" "$_ds_t0"

	# t2389: explicit tier:simple execution-contract guard.
	# Non-blocking: normalizes tier:simple → tier:standard when a present checklist
	# is incomplete or the issue lacks a canonical exact execution contract.
	# Always returns 0. Dispatch proceeds at the corrected tier on hit, or
	# unchanged tier on miss. See .agents/reference/task-taxonomy.md.
	# Label-mutating policy helpers emit one internal marker; metadata is refreshed
	# once after this guard and the self-hosting override have both run.
	_TIER_LABELS_MUTATED=0
	_ds_t0=$(_ds_now_ns)
	_run_tier_simple_body_shape_check "$issue_number" "$repo_slug"
	_ds_record "$issue_number" "$repo_slug" "tier_body_shape" "$_ds_t0"

	# GH#19118: Pre-dispatch validator — runs after dedup, before worker spawn.
	# Checks generator-tagged auto-generated issues to verify the premise is
	# still true. Exit 0 = dispatch proceeds; exit 10 = premise falsified
	# (issue already closed by validator); exit 20 = optional validator error
	# (dispatch proceeds with warning); exit 30 = duplicate-state uncertainty
	# (fail closed for this cycle); exit 40 = missing required worker context
	# (fail closed until the generated brief is repaired).
	_ds_t0=$(_ds_now_ns)
	_run_predispatch_validator "$issue_number" "$repo_slug"
	local _validator_rc=$?
	issue_meta_json=$(_refresh_issue_meta_after_tier_policy_checks \
		"$issue_number" "$repo_slug" "$issue_meta_json" "$_TIER_LABELS_MUTATED")
	local _review_followup_validator_required=0
	if printf '%s' "$issue_meta_json" | jq -e '[.labels[]?.name] | (index("review-followup") != null or index("source:review-scanner") != null)' >/dev/null 2>&1; then
		_review_followup_validator_required=1
	fi
	_ds_record "$issue_number" "$repo_slug" "predispatch_validator" "$_ds_t0"
	if [[ "$_validator_rc" -eq 10 ]]; then
		echo "[dispatch_with_dedup] Pre-dispatch validator falsified premise for #${issue_number} in ${repo_slug} — issue closed, not dispatching" >>"$LOGFILE"
		_release_dispatch_claim_on_abort "$issue_number" "$repo_slug" "$self_login" "predispatch_validator_closed"
		return 1
	fi
	if [[ "$_validator_rc" -eq 40 ]]; then
		echo "[dispatch_with_dedup] Pre-dispatch missing worker context for #${issue_number} in ${repo_slug}: generated brief lacks canonical Files Scope" >>"$LOGFILE"
		_release_dispatch_claim_on_abort "$issue_number" "$repo_slug" "$self_login" "missing_worker_context"
		return 1
	fi
	if [[ "$_review_followup_validator_required" -eq 1 && "$_validator_rc" -ne 0 ]]; then
		echo "[dispatch_with_dedup] Required review-followup validation failed for #${issue_number} in ${repo_slug} (rc=${_validator_rc}) — failing closed" >>"$LOGFILE"
		_release_dispatch_claim_on_abort "$issue_number" "$repo_slug" "$self_login" "predispatch_validator_uncertain"
		return 1
	fi
	if [[ "$_validator_rc" -eq 20 ]]; then
		echo "[dispatch_with_dedup] Pre-dispatch validator error for #${issue_number} in ${repo_slug} (rc=${_validator_rc}) — proceeding with dispatch" >>"$LOGFILE"
	fi
	if [[ "$_validator_rc" -eq 30 ]]; then
		echo "[dispatch_with_dedup] Pre-dispatch duplicate lookup uncertain for #${issue_number} in ${repo_slug} — failing closed for this cycle" >>"$LOGFILE"
		_release_dispatch_claim_on_abort "$issue_number" "$repo_slug" "$self_login" "predispatch_validator_uncertain"
		return 1
	fi

	# t2424/GH#20030: Generic eligibility gate — final check BEFORE worker spawn.
	_ds_t0=$(_ds_now_ns)
	if ! _run_eligibility_gate_or_abort "$issue_number" "$repo_slug" "$issue_meta_json"; then
		_ds_record "$issue_number" "$repo_slug" "$_PULSE_DISPATCH_ELIGIBILITY_STAGE" "$_ds_t0"
		_release_dispatch_claim_on_abort "$issue_number" "$repo_slug" "$self_login" "$_PULSE_DISPATCH_ELIGIBILITY_STAGE"
		return 1
	fi
	_ds_record "$issue_number" "$repo_slug" "$_PULSE_DISPATCH_ELIGIBILITY_STAGE" "$_ds_t0"
	return 0
}

_dispatch_launch_checked_worker() {
	local issue_number="$1" repo_slug="$2" dispatch_title="$3" issue_title="$4"
	local self_login="$5" repo_path="$6" prompt="$7" session_key="$8" model_override="$9"
	local _ds_t0=""

	# All checks passed — launch the worker.
	_ds_t0=$(_ds_now_ns)
	local _launch_rc=0
	_dispatch_launch_worker \
		"$issue_number" "$repo_slug" "$dispatch_title" "$issue_title" \
		"$self_login" "$repo_path" "$prompt" "$session_key" \
		"$model_override" "$issue_meta_json" || _launch_rc=$?
	_ds_record "$issue_number" "$repo_slug" "worker_launch_total" "$_ds_t0"
	if [[ "$_launch_rc" -ne 0 ]]; then
		local _launch_abort_reason="worker_launch_rc_${_launch_rc}"
		if [[ -n "${_DLW_LAST_PRE_RUNTIME_FAILURE:-}" ]]; then
			_launch_abort_reason="${_launch_abort_reason}:${_DLW_LAST_PRE_RUNTIME_FAILURE}"
		fi
		_release_dispatch_claim_on_abort "$issue_number" "$repo_slug" "$self_login" "$_launch_abort_reason"
	fi

	# t3034: record total ceremony time
	_ds_record "$issue_number" "$repo_slug" "ceremony_total" "$_ds_ceremony_t0"
	return "$_launch_rc"
}

#######################################
# t2063: Pre-dispatch brief-body freshness guard.
#
# If a task brief file exists at `${repo_path}/todo/tasks/${task_id}-brief.md`
# but the issue body does not contain the `## Task Brief` or `## Worker Guidance`
# marker, force-enrich the body via issue-sync-helper.sh. This ensures the
# worker sees the full implementation context on its first read of the issue,
# eliminating the ~1500-3000 token exploration overhead of hunting for the
# brief file inside the worktree.
#
# Defence-in-depth: the primary fixes in claim-task-id.sh (_compose_issue_body)
# and issue-sync-helper.sh (_enrich_update_issue) should make this a no-op in
# all normal paths. This guard catches:
#   - Legacy issues created via the pre-t2063 bare path before the TODO push
#   - Any future path that bypasses both primary fixes
#   - Briefs added after the issue was created
#
# Non-fatal: always returns 0 so dispatch proceeds even if enrich fails.
# The worker will still run, just with the pre-t2063 context cost.
#
# Arguments:
#   $1 - issue_number
#   $2 - repo_slug (owner/repo)
#   $3 - repo_path (local checkout)
#   $4 - issue_title (used to extract task ID)
#######################################
_ensure_issue_body_has_brief() {
	local issue_number="$1"
	local repo_slug="$2"
	local repo_path="$3"
	local issue_title="$4"
	# t2996: optional pre-fetched issue JSON (full bundle from
	# dispatch_with_dedup including `.body`). Skips the duplicate
	# `gh issue view --json body` call that this guard would otherwise
	# make as the 5th gh hit on the same candidate. Falls back to a
	# fresh fetch when omitted (defence-in-depth callers).
	local pre_fetched_json="${5:-}"

	# Extract task ID from title (format: "tNNN: description")
	local task_id=""
	[[ "$issue_title" =~ (t[0-9]+) ]] && task_id="${BASH_REMATCH[1]}"
	[[ -z "$task_id" ]] && return 0

	# Check for brief file on disk
	local brief_file="${repo_path}/todo/tasks/${task_id}-brief.md"
	[[ ! -f "$brief_file" ]] && return 0

	# Check if body already has substantial content (framework-synced markers OR
	# an externally-composed brief-style body).
	# Layer 4 (t2377): the narrow marker check mis-classified externally-
	# composed bodies as stubs. #19778/#19779/#19780 had "## What" / "## Why" /
	# "## How" bodies ~5KB each; the old check treated them as stubs and
	# force-enriched them into emptiness.
	local current_body
	if [[ -n "$pre_fetched_json" ]] &&
		printf '%s' "$pre_fetched_json" | jq -e '.body' >/dev/null 2>&1; then
		current_body=$(printf '%s' "$pre_fetched_json" | jq -r '.body // ""' 2>/dev/null) || current_body=""
	else
		# t3027: route through gh_issue_view wrapper for REST fallback under
		# GraphQL exhaustion. The `body` field name is identical between gh
		# native and REST shape, so --jq '.body' works on both paths.
		current_body=$(gh_issue_view "$issue_number" --repo "$repo_slug" --json body --jq '.body' 2>/dev/null || echo "")
	fi
	if [[ "$current_body" == *"## Task Brief"* ]] || [[ "$current_body" == *"## Worker Guidance"* ]]; then
		return 0
	fi
	# Brief-template-style headings count as substantial content too (layer 4).
	if [[ "$current_body" == *"## What"* ]] && [[ "$current_body" == *"## How"* ]]; then
		return 0
	fi
	# Fallback length heuristic: 500+ chars is unlikely to be a stub (layer 4).
	# Real stubs from claim-task-id.sh are <200 chars.
	if [[ ${#current_body} -ge 500 ]]; then
		return 0
	fi

	# Layer 5 (t2377): refuse to force-enrich when the task has a brief on disk
	# but no TODO.md entry. This combination makes compose_issue_body fail, and
	# the resulting empty body previously destroyed the issue content. The
	# correct behaviour in this case is: leave the existing (externally-
	# composed) body alone; the worker will read the brief from disk directly.
	local todo_file="${repo_path}/TODO.md"
	if [[ -f "$todo_file" ]]; then
		local task_id_ere
		# shellcheck disable=SC2016  # $ inside single quotes is a literal regex metachar, not a shell expansion
		task_id_ere=$(printf '%s' "$task_id" | sed 's/[].[\*^$()+?{|]/\\&/g')
		if ! grep -qE "^[[:space:]]*- \[.\] ${task_id_ere}( |$)" "$todo_file" 2>/dev/null; then
			echo "[dispatch_with_dedup] t2377: issue #${issue_number} has brief but no TODO.md entry; skipping force-enrich (safe: worker will read brief from disk)" >>"$LOGFILE"
			return 0
		fi
	fi

	# GH#19856: cross-runner dedup guard — before force-enriching, verify no
	# other runner holds an active claim. Even though dispatch_with_dedup
	# runs its dedup check upstream, this guard catches TOCTOU races where
	# another runner claims between the dedup check and the enrich call.
	local dedup_helper
	# GH#19922: use parameter expansion instead of external dirname command.
	dedup_helper="${BASH_SOURCE[0]%/*}/dispatch-dedup-helper.sh"
	if [[ -x "$dedup_helper" ]]; then
		local _dedup_out=""
		# GH#19922/GH#28498: preserve the self-login exemption while using the
		# read-only guard so enrichment cannot stale-recover active ownership.
		_dedup_out=$("$dedup_helper" is-assigned-read-only "$issue_number" "$repo_slug" "${AIDEVOPS_SESSION_USER:-}" 2>/dev/null) || true
		if [[ -n "$_dedup_out" ]]; then
			echo "[dispatch_with_dedup] GH#19856: skipping force-enrich for #${issue_number} — active claim: ${_dedup_out}" >>"$LOGFILE"
			return 0
		fi
	fi

	# Brief exists but body is a stub — force-enrich before worker sees it.
	# Run enrich from the repo_path so `find_project_root` resolves correctly,
	# and pass REPO_SLUG + FORCE_ENRICH via env so the helper skips the body
	# preservation gate and targets the right repo.
	echo "[dispatch_with_dedup] t2063: issue #${issue_number} has brief on disk but stub body — force-enriching" >>"$LOGFILE"
	local issue_sync_helper
	issue_sync_helper="$(dirname "${BASH_SOURCE[0]}")/issue-sync-helper.sh"
	if [[ -x "$issue_sync_helper" ]]; then
		(
			cd "$repo_path" 2>/dev/null || exit 0
			FORCE_ENRICH=true REPO_SLUG="$repo_slug" "$issue_sync_helper" enrich "$task_id" >>"$LOGFILE" 2>&1
		) || {
			echo "[dispatch_with_dedup] t2063: force-enrich failed for #${issue_number}; proceeding with stub body" >>"$LOGFILE"
		}
	fi
	return 0
}

#######################################
# GH#19118: Run the pre-dispatch validator for auto-generated issues.
#
# Delegates to pre-dispatch-validator-helper.sh validate <issue> <slug>.
# Non-fatal wrapper: if the helper is missing or fails unexpectedly, logs
# a warning and returns 0 (validator error semantics = dispatch proceeds).
#
# Arguments:
#   $1 - issue_number
#   $2 - repo_slug (owner/repo)
#
# Exit codes:
#   0  — dispatch proceeds (validator passed, unregistered generator, or helper missing)
#   10 — premise falsified; caller must NOT dispatch (issue already closed by validator)
#   20 — validator error; caller should log warning and continue dispatch
#   30 — duplicate-state uncertainty; caller must fail closed
#######################################
_record_tier_policy_output() {
	local helper_output="$1"
	if [[ -z "$helper_output" ]]; then
		return 0
	fi
	printf '%s\n' "$helper_output" >>"$LOGFILE"
	if [[ "$helper_output" == *"[aidevops:tier-labels-mutated]"* ]]; then
		_TIER_LABELS_MUTATED=1
	fi
	return 0
}

_run_predispatch_validator() {
	local issue_number="$1"
	local repo_slug="$2"

	local validator_helper
	validator_helper="$(dirname "${BASH_SOURCE[0]}")/pre-dispatch-validator-helper.sh"
	if [[ ! -x "$validator_helper" ]]; then
		echo "[dispatch_with_dedup] GH#19118: pre-dispatch-validator-helper.sh not found — validator unavailable" >>"$LOGFILE"
		return 20
	fi

	local validator_rc=0 validator_output=""
	validator_output=$("$validator_helper" validate "$issue_number" "$repo_slug" 2>&1) || validator_rc=$?
	_record_tier_policy_output "$validator_output"
	return "$validator_rc"
}

#######################################
# t2389: tier:simple body-shape check wrapper (GH#19929).
#
# Invokes tier-simple-body-shape-helper.sh on any issue tagged tier:simple;
# the helper auto-downgrades to tier:standard + posts a feedback comment
# when the body contains a disqualifier from reference/task-taxonomy.md
# "Tier Assignment Validation". Non-blocking by design — always exits 0
# from the helper's perspective (dispatch always proceeds, at whatever
# tier the labels now indicate).
#
# Arguments:
#   $1 - issue_number
#   $2 - repo_slug (owner/repo)
#
# Exit codes:
#   0 — always (non-blocking by design)
#######################################
_run_tier_simple_body_shape_check() {
	local issue_number="$1"
	local repo_slug="$2"

	local check_helper
	check_helper="$(dirname "${BASH_SOURCE[0]}")/tier-simple-body-shape-helper.sh"
	if [[ ! -x "$check_helper" ]]; then
		# Helper missing is non-fatal — just log and continue. The dispatch
		# pipeline must never block on a missing optional helper.
		echo "[dispatch_with_dedup] t2389: tier-simple-body-shape-helper.sh not found — skipping" >>"$LOGFILE"
		return 0
	fi

	# Always pass regardless of helper exit code. Capture the mutation marker so
	# the caller can refresh bundled metadata once after all tier policy checks.
	local check_output=""
	check_output=$("$check_helper" check "$issue_number" "$repo_slug" 2>&1) || true
	_record_tier_policy_output "$check_output"
	return 0
}

#######################################
# Refresh bundled issue metadata after tier policy label mutation.
#
# The simple-contract guard and self-hosting detector may normalize tier labels
# on GitHub. Refresh once when either emitted the internal mutation marker so
# eligibility and worker model resolution consume the normalized single tier.
#
# Arguments:
#   $1 - issue_number
#   $2 - repo_slug (owner/repo)
#   $3 - current issue_meta_json bundle
#   $4 - mutation flag (1 when a policy helper changed labels)
#
# Output:
#   refreshed issue_meta_json when available; otherwise the original bundle
# Exit codes:
#   0 — always (fail-open metadata refresh)
#######################################
_refresh_issue_meta_after_tier_policy_checks() {
	local issue_number="$1"
	local repo_slug="$2"
	local issue_meta_json="$3"
	local tier_labels_mutated="$4"

	if [[ "$tier_labels_mutated" != "1" ]]; then
		printf '%s' "$issue_meta_json"
		return 0
	fi

	local refreshed_issue_meta_json
	refreshed_issue_meta_json=$(gh_issue_view "$issue_number" --repo "$repo_slug" \
		--json number,title,state,labels,assignees,body,author,createdAt 2>/dev/null) || refreshed_issue_meta_json=""
	if [[ -z "$refreshed_issue_meta_json" ]]; then
		echo "[dispatch_with_dedup] unable to refresh issue metadata after tier policy mutation for #${issue_number} in ${repo_slug}; continuing with original snapshot" >>"$LOGFILE"
		printf '%s' "$issue_meta_json"
		return 0
	fi

	printf '%s' "$refreshed_issue_meta_json"
	return 0
}

#######################################
# Check issue comments for terminal blocker patterns (GH#5141)
#
# Scans the last N comments on an issue for known patterns that indicate
# a user-action-required blocker. Workers cannot resolve these — they
# require the repo owner to take a manual action (e.g., refresh a token,
# grant a scope, configure a secret). Dispatching workers against these
# issues wastes compute on guaranteed failures.
#
# Known terminal blocker patterns:
#   - workflow scope missing (token lacks `workflow` scope)
#   - token lacks scope / missing scope
#   - ACTION REQUIRED (supervisor-posted user-action comments)
#   - refusing to allow an OAuth App to create or update workflow
#   - authentication required / permission denied (persistent auth failures)
#
# When a blocker is detected, the function:
#   1. Adds `status:blocked` label to the issue
#   2. Posts a comment directing the user to the required action
#      (idempotent — checks for existing blocker comment first)
#
# Arguments:
#   $1 - issue number
#   $2 - repo slug (owner/repo)
#   $3 - (optional) max comments to scan (default: 5)
#
# Exit codes:
#   0 - terminal blocker detected (skip dispatch)
#   1 - no blocker found (safe to dispatch)
#   2 - API error (fail open — allow dispatch to proceed)
#######################################
#######################################
# Match terminal blocker patterns in comment bodies (GH#5627)
#
# Checks concatenated comment bodies against known blocker patterns.
# Returns blocker_reason and user_action via stdout (2 lines).
#
# Arguments:
#   $1 - all_bodies (concatenated comment text)
# Output: 2 lines to stdout (blocker_reason, user_action) — empty if no match
# Exit codes:
#   0 - blocker pattern matched
#   1 - no match
#######################################
_match_terminal_blocker_pattern() {
	local all_bodies="$1"
	local blocker_reason=""
	local user_action=""

	# Pattern 1: GitHub CLI too old for gh api --paginate --slurp
	if echo "$all_bodies" | grep -qiE 'unknown flag: --slurp'; then
		local gh_slurp_message=""
		if declare -F aidevops_gh_slurp_status_message >/dev/null 2>&1; then
			gh_slurp_message=$(aidevops_gh_slurp_status_message)
		else
			gh_slurp_message="GitHub CLI (gh) is too old for gh api --paginate --slurp; upgrade gh to >= 2.51.0."
		fi
		blocker_reason="GitHub CLI prerequisite failed — ${gh_slurp_message}"
		user_action="Upgrade GitHub CLI to a version that supports \`gh api --paginate --slurp\` (minimum gh ${AIDEVOPS_GH_MIN_SLURP_VERSION:-2.51.0}), then remove the \`status:blocked\` label."
	# Pattern 2: workflow scope missing
	elif echo "$all_bodies" | grep -qiE 'workflow scope|refusing to allow an OAuth App to create or update workflow|token lacks.*workflow'; then
		blocker_reason="GitHub token lacks \`workflow\` scope — workers cannot push workflow file changes"
		user_action="Run \`gh auth refresh -s workflow\` to add the workflow scope to your token, then remove the \`status:blocked\` label."
	# Pattern 3: generic token/auth scope issues
	elif echo "$all_bodies" | grep -qiE 'token lacks.*scope|missing.*scope.*token|token.*missing.*scope'; then
		blocker_reason="GitHub token is missing a required scope — workers cannot complete this task"
		user_action="Check the error details in the comments above, run \`gh auth refresh -s <missing-scope>\` to add the required scope, then remove the \`status:blocked\` label."
	# Pattern 4: ACTION REQUIRED (supervisor-posted)
	elif echo "$all_bodies" | grep -qF 'ACTION REQUIRED'; then
		blocker_reason="A previous supervisor comment flagged this issue as requiring user action"
		user_action="Read the ACTION REQUIRED comment above, complete the requested action, then remove the \`status:blocked\` label."
	# Pattern 5: persistent authentication/permission failures
	elif echo "$all_bodies" | grep -qiE 'authentication required.*workflow|permission denied.*workflow|push declined.*workflow'; then
		blocker_reason="Persistent authentication or permission failure for workflow files"
		user_action="Check your GitHub token scopes with \`gh auth status\`, refresh if needed with \`gh auth refresh -s workflow\`, then remove the \`status:blocked\` label."
	fi

	if [[ -z "$blocker_reason" ]]; then
		return 1
	fi

	echo "$blocker_reason"
	echo "$user_action"
	return 0
}

#######################################
# Apply terminal blocker labels and comment to an issue (GH#5627)
#
# Idempotent — checks for existing label and comment before acting.
#
# Arguments:
#   $1 - issue_number
#   $2 - repo_slug
#   $3 - blocker_reason
#   $4 - user_action
#   $5 - all_bodies (for existing comment check)
#######################################
_apply_terminal_blocker() {
	local issue_number="$1"
	local repo_slug="$2"
	local blocker_reason="$3"
	local user_action="$4"
	local all_bodies="$5"

	# Check if already labelled
	local existing_labels
	existing_labels=$(gh_issue_view "$issue_number" --repo "$repo_slug" \
		--json labels --jq '[.labels[].name] | join(",")' 2>/dev/null) || existing_labels=""

	local already_blocked=0
	if [[ ",${existing_labels}," == *",status:blocked,"* ]]; then
		already_blocked=1
	fi

	# Add label if not already present (t2033: use set_issue_status to atomically
	# clear all sibling status:* labels, not just available/queued)
	if [[ "$already_blocked" -eq 0 ]]; then
		set_issue_status "$issue_number" "$repo_slug" "blocked" || true
	fi

	# Post comment if not already posted (idempotent — safe against concurrent pulses)
	local blocker_body="**Terminal blocker detected** (GH#5141) — skipping dispatch.

**Reason:** ${blocker_reason}

**Action required:** ${user_action}

---
*This issue will not be dispatched to workers until the blocker is resolved. Once you have completed the required action, remove the \`status:blocked\` label to re-enable dispatch.*"

	_gh_idempotent_comment "$issue_number" "$repo_slug" \
		"Terminal blocker detected" "$blocker_body"

	return 0
}

check_terminal_blockers() {
	local issue_number="$1"
	local repo_slug="$2"
	local max_comments="${3:-5}"
	[[ "$max_comments" =~ $_PULSE_DISPATCH_UNSIGNED_INTEGER_PATTERN ]] || max_comments=5

	if [[ -z "$issue_number" || -z "$repo_slug" ]]; then
		echo "[pulse-wrapper] check_terminal_blockers: missing arguments" >>"$LOGFILE"
		return 2
	fi

	if [[ ! "$issue_number" =~ $_PULSE_DISPATCH_UNSIGNED_INTEGER_PATTERN ]]; then
		return 2
	fi

	# Fetch the last N comments
	local comments_json
	comments_json=$(gh api "repos/${repo_slug}/issues/${issue_number}/comments" \
		--jq "[ .[-${max_comments}:][] | {body: .body, created_at: .created_at} ]" 2>/dev/null)
	local api_exit=$?

	if [[ $api_exit -ne 0 ]]; then
		echo "[pulse-wrapper] check_terminal_blockers: API error (exit=$api_exit) for #${issue_number} in ${repo_slug} — failing open" >>"$LOGFILE"
		return 2
	fi

	if [[ -z "$comments_json" || "$comments_json" == "[]" || "$comments_json" == "null" ]]; then
		return 1
	fi

	# Concatenate comment bodies for pattern matching
	local all_bodies
	all_bodies=$(echo "$comments_json" | jq -r '.[].body // ""' 2>/dev/null)

	if [[ -z "$all_bodies" ]]; then
		return 1
	fi

	# Match against known terminal blocker patterns
	local pattern_output
	pattern_output=$(_match_terminal_blocker_pattern "$all_bodies") || return 1

	local blocker_reason="" user_action=""
	blocker_reason=$(echo "$pattern_output" | sed -n '1p')
	user_action=$(echo "$pattern_output" | sed -n '2p')

	# Apply labels and comment
	_apply_terminal_blocker "$issue_number" "$repo_slug" "$blocker_reason" "$user_action" "$all_bodies"

	echo "[pulse-wrapper] check_terminal_blockers: blocker detected for #${issue_number} in ${repo_slug} — ${blocker_reason}" >>"$LOGFILE"
	return 0
}
