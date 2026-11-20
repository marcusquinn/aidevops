#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# pulse-issue-reconcile-normalize.sh — Label invariant normalization helpers
# =============================================================================
# Extracted from pulse-issue-reconcile.sh (GH#21376) to keep the orchestrator
# file below the 2000-line file-size-debt gate. Mirrors the split precedent
# from pulse-issue-reconcile-stale.sh (t2375).
#
# Sourced by pulse-issue-reconcile.sh. Do NOT invoke directly — it relies on
# the orchestrator (pulse-wrapper.sh) having sourced shared-constants.sh and
# worker-lifecycle-common.sh and defined LOGFILE, REPOS_JSON, and
# PULSE_QUEUED_SCAN_LIMIT, plus the ISSUE_STATUS_LABELS, ISSUE_STATUS_LABEL_PRECEDENCE,
# and ISSUE_TIER_LABEL_RANK arrays from shared-constants.sh.
#
# Usage: source "${SCRIPT_DIR}/pulse-issue-reconcile-normalize.sh"
#
# Exports:
#   _filter_core_status_labels         — filter status list to core labels
#   _pick_status_survivor              — select winner from core status array
#   _pick_tier_survivor                — select winner from tier array
#   _enforce_status_invariant_one_issue — fix multi-status issues
#   _enforce_tier_invariant_one_issue   — fix multi-tier issues
#   _enforce_persistent_task_invariant_one_issue — unblock finite tasks
#   _fetch_label_invariant_rows        — fetch per-repo issue rows for invariant check
#   _normalize_label_invariants_for_repo — per-repo invariant pass
#   _write_label_invariants_counter_file — persist cycle counters for t2041
#   _normalize_label_invariants        — coordinator (t2040 Phase 3)

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard — prevent double-sourcing.
[[ -n "${_PULSE_ISSUE_RECONCILE_NORMALIZE_LOADED:-}" ]] && return 0
_PULSE_ISSUE_RECONCILE_NORMALIZE_LOADED=1
[[ -n "${_LI_BOOL_TRUE+x}" ]] || _LI_BOOL_TRUE="true"
[[ -n "${_LI_BOOL_FALSE+x}" ]] || _LI_BOOL_FALSE="false"
[[ -n "${_LI_PERSISTENT_LABEL+x}" ]] || _LI_PERSISTENT_LABEL="persistent"
_LI_BLOCKED_STATUS="blocked"
_LI_AVAILABLE_STATUS="available"
_LI_BLOCKED_CSV=",status:${_LI_BLOCKED_STATUS},"
_LI_AI_RECOVERY="needs-ai-recovery"
# GH#38821: shared human-hold label list (also used by dependency-event-reconciler.sh).
if ! declare -F issue_labels_csv_have_human_hold >/dev/null 2>&1; then
	_li_lib_dir="${BASH_SOURCE[0]%/*}"
	[[ "$_li_lib_dir" == "${BASH_SOURCE[0]}" ]] && _li_lib_dir="."
	# shellcheck source=./issue-hold-marker-lib.sh
	[[ -r "${_li_lib_dir}/issue-hold-marker-lib.sh" ]] && source "${_li_lib_dir}/issue-hold-marker-lib.sh"
	unset _li_lib_dir
fi

#######################################
# (t2040 Phase 3 helper) Enforce label invariants across all open issues.
#
# Walks every open issue in every pulse-enabled repo and enforces:
#
#   1. At most one core `status:*` label. When multiple are present,
#      the survivor is picked by ISSUE_STATUS_LABEL_PRECEDENCE
#      (`done > in-review > in-progress > queued > claimed > available
#      > blocked`). `done` is terminal — it always wins if present.
#      Atomic migration via `set_issue_status`.
#
#   2. At most one `tier:*` label. Rank matches
#      .github/workflows/dedup-tier-labels.yml so this pass is idempotent
#      with the GH Action: rank `reasoning > standard > simple`.
#      Auto-dispatch issues with no tier receive conservative `tier:standard`
#      without changing their dispatch, review, or hold labels.
#
#   3. Finite publication-backed tasks cannot also be generic persistent
#      trackers. Remove only `persistent` when publication and lifecycle
#      evidence coexist, while preserving explicit dashboard/routine identities.
#
#   4. GH#38360: `status:blocked` carries a `needs-*` companion. A bare hold
#      gets `needs-ai-recovery`; blocked-owned companions (`needs-ai-recovery`,
#      `needs-dependency`, `needs-maintainer-input`) on a non-blocked issue
#      are removed. Both repairs re-read live labels before writing.
#      GH#38821: a bare hold carrying a human hold label (hold-for-review,
#      no-auto-dispatch) gets `needs-maintainer-input` instead, and a hold
#      re-queued as `needs-ai-recovery` after the hold is healed to it.
#
# Also counts (but does not auto-fix) triage-missing issues — those with
# `origin:interactive` label AND no `tier:*` AND no `auto-dispatch` AND no
# `status:*` AND created >30min ago. These need human tier assignment and
# brief creation; surfaced via the summary log line so the LLM sweep
# (t2041) can highlight them in the Hygiene Anomalies section.
#
# This pass is the backfill path for the 14 already-polluted issues left
# by the write-without-remove bug (fixed forward by PR #18519 / t2033)
# and the tier concatenation bug (fixed forward by PR #18441 / t1997).
# After a single pulse cycle post-merge, polluted state should normalize.
#
# Args:
#   $1 runner_user — GH login of the current runner (unused, kept for
#                    symmetry with other _normalize_* helpers)
#   $2 repos_json  — path to repos.json
# Returns: 0 always (best-effort; logs counters to $LOGFILE)
#######################################
# Helper: filter a space-separated list of status names down to those
# that are members of ISSUE_STATUS_LABELS. Used by the status-invariant
# check to ignore out-of-band labels (needs-info, verify-failed, etc.)
# which can legitimately coexist with a core status.
#
# Writes the result to the global array _LI_FILTERED_STATUS (bash 3.2
# has no namerefs; eval-based output patterns break under `set -u` when
# the result array is empty).
#
# Args:
#   $1 - space-separated status names (e.g. "available queued")
_filter_core_status_labels() {
	local status_list="$1"
	_LI_FILTERED_STATUS=()
	local _s="" _core_label=""
	[[ -n "$status_list" ]] || return 0
	for _s in $status_list; do
		for _core_label in "${ISSUE_STATUS_LABELS[@]}"; do
			if [[ "$_s" == "$_core_label" ]]; then
				_LI_FILTERED_STATUS+=("$_s")
				break
			fi
		done
	done
	return 0
}

# Helper: given an array of core status names, pick the survivor per
# ISSUE_STATUS_LABEL_PRECEDENCE and emit it on stdout. Empty if none.
_pick_status_survivor() {
	local _precedent="" _current=""
	local _has_available="" _has_blocked="" _has_active=""
	local _blocked_status="blocked"
	for _current in "$@"; do
		[[ "$_current" == "$_LI_AVAILABLE_STATUS" ]] && _has_available="1"
		[[ "$_current" == "$_blocked_status" ]] && _has_blocked="1"
		[[ "$_current" != "$_LI_AVAILABLE_STATUS" && "$_current" != "$_blocked_status" ]] && _has_active="1"
	done
	# A dual blocked/available state is unsafe regardless of ordinary lifecycle
	# precedence: queue readers may otherwise advertise the issue before the
	# dependency pass repairs it. Fail closed and make the pair exclusive.
	if [[ -n "$_has_available" && -n "$_has_blocked" && -z "$_has_active" ]]; then
		echo "$_blocked_status"
		return 0
	fi
	for _precedent in "${ISSUE_STATUS_LABEL_PRECEDENCE[@]}"; do
		for _current in "$@"; do
			if [[ "$_current" == "$_precedent" ]]; then
				echo "$_precedent"
				return 0
			fi
		done
	done
	return 0
}

# Helper: given an array of tier names, pick the survivor per
# ISSUE_TIER_LABEL_RANK and emit it on stdout. Empty if none.
_pick_tier_survivor() {
	local _rank="" _current_tier=""
	for _rank in "${ISSUE_TIER_LABEL_RANK[@]}"; do
		for _current_tier in "$@"; do
			if [[ "$_current_tier" == "$_rank" ]]; then
				echo "$_rank"
				return 0
			fi
		done
	done
	return 0
}

# Helper: enforce status invariant for one issue. Caller passes the
# already-filtered core_status names as positional args (guaranteed
# by the caller to have length >1). Returns 0 if a fix was applied.
_enforce_status_invariant_one_issue() {
	local issue_num="$1" slug="$2"
	shift 2
	local survivor
	survivor=$(_pick_status_survivor "$@")
	[[ -n "$survivor" ]] || return 1

	echo "[pulse-wrapper] label_invariants: #${issue_num} in ${slug} had status labels [$*] -> keeping '${survivor}'" >>"$LOGFILE"
	set_issue_status "$issue_num" "$slug" "$survivor" >/dev/null 2>&1 || true
	return 0
}

# Helper: enforce tier invariant for one issue. Caller passes tier
# names as positional args (guaranteed to have length >1).
_enforce_tier_invariant_one_issue() {
	local issue_num="$1" slug="$2"
	shift 2
	local tier_survivor
	tier_survivor=$(_pick_tier_survivor "$@")
	[[ -n "$tier_survivor" ]] || return 1

	echo "[pulse-wrapper] label_invariants: #${issue_num} in ${slug} had tier labels [$*] -> keeping 'tier:${tier_survivor}'" >>"$LOGFILE"
	local -a tier_flags=()
	local _losing
	for _losing in "$@"; do
		if [[ "$_losing" != "$tier_survivor" ]]; then
			tier_flags+=(--remove-label "tier:${_losing}")
		fi
	done
	[[ "${#tier_flags[@]}" -gt 0 ]] || return 1
	gh issue edit "$issue_num" --repo "$slug" "${tier_flags[@]}" >/dev/null 2>&1 || true
	return 0
}

# Remove a contradictory generic persistent marker from a finite task.
# publication:pending remains intact because only the publication reconciler
# may clear that hold after verifying canonical planning on the default branch.
_enforce_persistent_task_invariant_one_issue() {
	local issue_num="$1" slug="$2"
	if gh issue edit "$issue_num" --repo "$slug" --remove-label "$_LI_PERSISTENT_LABEL" >/dev/null 2>&1; then
		echo "[pulse-wrapper] label_invariants: removed contradictory persistent label from finite task #${issue_num} in ${slug}" >>"$LOGFILE"
		return 0
	fi
	echo "[pulse-wrapper] label_invariants: failed to remove contradictory persistent label from #${issue_num} in ${slug}" >>"$LOGFILE"
	return 1
}

# GH#38821 heal: succeeds (0) only when the latest needs-ai-recovery label event
# postdates the latest human-hold label event and no CLAIM_RELEASED or
# terminal-blocker comment followed that hold, i.e. the normalizer, not a worker
# blocker, re-queued a maintainer hold. Any lookup failure returns 1 (leave as is).
_blocked_companion_hold_requeue_is_stale() {
	local issue_num="$1" slug="$2"
	local hold_at="" ai_at="" blockers="" times=""
	local hold_re="${ISSUE_HUMAN_HOLD_LABELS// /|}"
	times=$(gh api --paginate "repos/${slug}/issues/${issue_num}/events?per_page=100" \
		--jq '.[] | select(.event == "labeled") | select(.label.name | test("^('"${_LI_AI_RECOVERY}|${hold_re}"')$")) | "\(.label.name)\t\(.created_at)"' 2>/dev/null) || return 1
	hold_at=$(printf '%s\n' "$times" | awk -F'\t' -v ai="$_LI_AI_RECOVERY" '$1 != ai && $2 > m {m = $2} END {print m}')
	ai_at=$(printf '%s\n' "$times" | awk -F'\t' -v ai="$_LI_AI_RECOVERY" '$1 == ai && $2 > m {m = $2} END {print m}')
	[[ -n "$hold_at" && -n "$ai_at" && "$ai_at" > "$hold_at" ]] || return 1
	blockers=$(gh api --paginate "repos/${slug}/issues/${issue_num}/comments?per_page=100" \
		--jq '.[] | select(.created_at >= "'"$hold_at"'") | select(.body | test("CLAIM_RELEASED|terminal[-_ ]blocker"; "i")) | .id' 2>/dev/null) || return 1
	[[ -z "$blockers" ]] || return 1
	return 0
}

# GH#38360: status:blocked always carries a needs-* companion that names what
# unblocks it, and blocked-owned companions leave with status:blocked. The
# listing row is a hint; both repairs re-read live labels first so a racing
# lifecycle write is never undone. Returns 0 when a repair was applied.
#
# A bare status:blocked routes to needs-ai-recovery: the recovery supervisor
# solves or releases it, or names the one human input with a specific label.
_enforce_blocked_companion_one_issue() {
	local issue_num="$1" slug="$2" mode="$3"
	local live="" label=""
	local -a edit_flags=()
	live=$(gh api "repos/${slug}/issues/${issue_num}" \
		--jq 'select(.state == "open") | [.labels[]?.name] | join(",")' 2>/dev/null) || return 1
	[[ -n "$live" ]] || return 1
	live=",${live},"
	case "$mode" in
	bare)
		[[ "$live" == *"$_LI_BLOCKED_CSV"* && "$live" != *",needs-"* ]] || return 1
		label="${BLOCKED_NEEDS_AI_RECOVERY:-$_LI_AI_RECOVERY}"
		# GH#38821: a human-owned hold waits on a maintainer decision, not AI
		# recovery, which would only rediscover the same hold.
		if declare -F issue_labels_csv_have_human_hold >/dev/null 2>&1 &&
			issue_labels_csv_have_human_hold "$live"; then
			label="${BLOCKED_NEEDS_MAINTAINER_INPUT:-needs-maintainer-input}"
		fi
		# An open native blocker (rc 0) is a dependency hold, not recovery work;
		# rc 1/2/3 (none, clear, unavailable) keep the recovery fallback.
		local native_rc=1
		if declare -F _blocked_by_check_native_relationships >/dev/null 2>&1; then
			_blocked_by_check_native_relationships "$slug" "$issue_num" >/dev/null 2>&1 && native_rc=0 || native_rc=$?
		fi
		[[ "$native_rc" -ne 0 ]] || label="${BLOCKED_NEEDS_DEPENDENCY:-needs-dependency}"
		if declare -F ensure_blocked_companion_label >/dev/null 2>&1; then
			ensure_blocked_companion_label "$slug" "$label" || true
		fi
		edit_flags=(--add-label "$label")
		;;
	hold_heal)
		[[ "$live" == *"$_LI_BLOCKED_CSV"* && "$live" == *",${_LI_AI_RECOVERY},"* ]] || return 1
		declare -F issue_labels_csv_have_human_hold >/dev/null 2>&1 &&
			issue_labels_csv_have_human_hold "$live" || return 1
		_blocked_companion_hold_requeue_is_stale "$issue_num" "$slug" || return 1
		label="${BLOCKED_NEEDS_MAINTAINER_INPUT:-needs-maintainer-input}"
		if declare -F ensure_blocked_companion_label >/dev/null 2>&1; then
			ensure_blocked_companion_label "$slug" "$label" || true
		fi
		edit_flags=(--remove-label "$_LI_AI_RECOVERY" --add-label "$label")
		;;
	orphan)
		# Require a live core status other than blocked; a statusless hold keeps
		# its human companion.
		[[ "$live" != *"$_LI_BLOCKED_CSV"* && "$live" == *",status:"* ]] || return 1
		for label in "$_LI_AI_RECOVERY" needs-dependency needs-maintainer-input; do
			[[ "$live" == *",${label},"* ]] && edit_flags+=(--remove-label "$label")
		done
		;;
	*) return 1 ;;
	esac
	[[ "${#edit_flags[@]}" -gt 0 ]] || return 1
	gh issue edit "$issue_num" --repo "$slug" "${edit_flags[@]}" >/dev/null 2>&1 || return 1
	echo "[pulse-wrapper] label_invariants: #${issue_num} in ${slug} blocked companion repair (${mode}): ${edit_flags[*]}" >>"$LOGFILE"
	return 0
}

# t19179: active ownership statuses only mean something while an assignee
# holds the claim. A missing assignee means half of the claim is already gone.
_LI_ORPHAN_ACTIVE_RE=",status:(claimed|in-review|in-progress|queued),"

# Post the CLAIM_RELEASED audit for an orphaned status. Returns non-zero when
# the comment cannot be persisted; the caller then writes no label (GH#35218).
_post_orphan_status_release_audit() {
	local issue_num="$1" slug="$2" idle_hours="$3" status_name="$4"
	local release_ts="" body=""
	release_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	body="<!-- ops:start — workers: skip this comment, it is audit trail not implementation context -->
CLAIM_RELEASED reason=orphaned_status_no_assignee status=${status_name} idle_hours=${idle_hours} ts=${release_ts}
<!-- ops:end -->"
	gh api "repos/${slug}/issues/${issue_num}/comments" \
		--method POST --field body="$body" >/dev/null 2>&1 || return 1
	return 0
}

# t19179: release an active status label that has no assignee, no recent
# activity and no open linked PR. Re-reads the live issue first; the listing
# row is only a hint. Fails closed on any indeterminate evidence and never
# writes a label unless the audit comment was persisted. Only the core status
# changes: holds, needs-* and tier labels are untouched.
# Args: $1 issue, $2 slug, $3 now epoch, $4 idle threshold hours
# Returns: 0 when released, 1 otherwise
_enforce_orphan_active_status_one_issue() {
	local issue_num="$1" slug="$2" now_epoch="$3" hours="$4"
	local live="" labels="" assignees="" updated_epoch="" status_name="" idle_hours=0
	live=$(gh api "repos/${slug}/issues/${issue_num}" \
		--jq 'select(.state == "open") | [([.labels[]?.name] | join(",")), ((.assignees // []) | length | tostring), (.updated_at | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601 | tostring)] | join("|")' 2>/dev/null) || return 1
	[[ -n "$live" ]] || return 1
	IFS='|' read -r labels assignees updated_epoch <<<"$live"
	[[ "$assignees" == "0" && "$updated_epoch" =~ ^[0-9]+$ ]] || return 1
	labels=",${labels},"
	[[ "$labels" =~ $_LI_ORPHAN_ACTIVE_RE ]] || return 1
	status_name="${BASH_REMATCH[1]}"
	# Exactly one core status: multi-status issues belong to the status invariant.
	[[ "$labels" != *",status:${_LI_AVAILABLE_STATUS},"* && "$labels" != *"$_LI_BLOCKED_CSV"* && "$labels" != *",status:done,"* ]] || return 1
	[[ "$labels" != *",parent-task,"* ]] || return 1
	idle_hours=$(((now_epoch - updated_epoch) / 3600))
	[[ "$idle_hours" -ge "$hours" ]] || return 1
	# Indeterminate PR evidence (or an unavailable helper) blocks the release.
	declare -F _normalize_stale_open_pr_blocks_reset >/dev/null 2>&1 || return 1
	declare -F set_issue_status >/dev/null 2>&1 || return 1
	_normalize_stale_open_pr_blocks_reset "$issue_num" "$slug" && return 1
	if ! _post_orphan_status_release_audit "$issue_num" "$slug" "$idle_hours" "$status_name"; then
		echo "[pulse-wrapper] label_invariants: orphan status release skipped (audit comment failed): #${issue_num} in ${slug}" >>"$LOGFILE"
		return 1
	fi
	set_issue_status "$issue_num" "$slug" "$_LI_AVAILABLE_STATUS" >/dev/null 2>&1 || return 1
	echo "[pulse-wrapper] label_invariants: #${issue_num} in ${slug} released orphaned status:${status_name} (no assignee, idle ${idle_hours}h)" >>"$LOGFILE"
	return 0
}

# An existing auto-dispatch label is the only authority needed for this
# conservative metadata repair. Do not add auto-dispatch, clear holds, or
# alter needs-maintainer-review; this only makes already-authorized work
# routable with the framework's default tier before pickup.
_backfill_auto_dispatch_tier_one_issue() {
	local issue_num="$1" slug="$2"
	gh issue edit "$issue_num" --repo "$slug" --add-label "tier:standard" >/dev/null 2>&1 || return 1
	echo "[pulse-wrapper] label_invariants: backfilled tier:standard on auto-dispatch #${issue_num} in ${slug}" >>"$LOGFILE"
	return 0
}

# t19179: listing-row gate for the orphan release. Cheap hint checks only
# (active status, zero assignees, idle past ORPHAN_STATUS_RELEASE_HOURS), then
# the live re-read in _enforce_orphan_active_status_one_issue.
# Args: $1 issue, $2 slug, $3 status name, $4 assignee count, $5 updated epoch
_orphan_status_row_release() {
	local issue_num="$1" slug="$2" status_name="$3" assignee_count="$4" updated_epoch="$5"
	local hours="${ORPHAN_STATUS_RELEASE_HOURS:-24}" now_epoch=""
	[[ "$assignee_count" == "0" && "$updated_epoch" =~ ^[0-9]+$ ]] || return 1
	[[ "$status_name" =~ ^(claimed|in-review|in-progress|queued)$ ]] || return 1
	[[ "$hours" =~ ^[0-9]+$ && "$hours" -ge 1 ]] || hours=24
	now_epoch=$(date +%s)
	[[ "$updated_epoch" -lt $((now_epoch - hours * 3600)) ]] || return 1
	_enforce_orphan_active_status_one_issue "$issue_num" "$slug" "$now_epoch" "$hours" || return 1
	return 0
}

# Helper: fetch issues for a repo and emit '|'-delimited rows per issue.
# See delimiter note in _normalize_label_invariants_for_repo.
_fetch_label_invariant_rows() {
	local slug="$1"
	# t2773: route through gh_issue_list wrapper (REST fallback on rate-limit exhaustion).
	# This fetch needs createdAt which is not in the prefetch cache, so the cache cannot
	# serve it — gh_issue_list is used directly (not the cache path).
	local issues_json="" _listing_rc=0
	if declare -F _normalize_repo_listing >/dev/null 2>&1; then
		issues_json=$(_normalize_repo_listing "$slug") || _listing_rc=$?
	else
		_listing_rc=2
	fi
	if [[ "$_listing_rc" -eq 2 ]]; then
		issues_json=$(gh_issue_list --repo "$slug" --state open \
			--json number,labels,createdAt,assignees,updatedAt --limit "$PULSE_QUEUED_SCAN_LIMIT" 2>/dev/null) || issues_json=""
	elif [[ "$_listing_rc" -ne 0 ]]; then
		issues_json=""
	fi
	[[ -n "$issues_json" && "$issues_json" != "null" ]] || return 1
	if [[ "$_listing_rc" -eq 0 ]]; then
		# Shared listing is wider than the scan window: re-apply the bound.
		issues_json=$(printf '%s' "$issues_json" | jq -c --argjson n "$PULSE_QUEUED_SCAN_LIMIT" '.[0:$n]' 2>/dev/null) || return 1
	fi

	# has_any_status counts ALL status:* labels (core + exception) so the
	# triage-missing counter correctly ignores issues that are actively
	# managed via an exception label (needs-info, verify-failed, stale,
	# needs-testing, orphaned). See CodeRabbit review on PR #18546.
	printf '%s' "$issues_json" | jq -r --arg persistent "$_LI_PERSISTENT_LABEL" --arg ai "$_LI_AI_RECOVERY" --arg holds "${ISSUE_HUMAN_HOLD_LABELS:-hold-for-review no-auto-dispatch}" '
		.[] | (.labels // []) as $labels | [
			(.number | tostring),
			([$labels[].name | select(startswith("status:")) | sub("^status:"; "")] | join(" ")),
			([$labels[].name | select(startswith("tier:"))   | sub("^tier:";   "")] | join(" ")),
			(any($labels[].name; . == "origin:interactive") | tostring),
			(any($labels[].name; . == "auto-dispatch")      | tostring),
			(any($labels[].name; . == ("supervisor", "contributor", "quality-review", "needs-maintainer-review", "routine-tracking", "on hold", "release-approval-required", "release-standing-policy") or . == $persistent) | tostring),
			(.createdAt | sub("\\.[0-9]+Z$"; "Z") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime | tostring),
			(([$labels[].name | select(startswith("status:"))] | length) | tostring),
			(any($labels[].name; . == $persistent) | tostring),
			(any($labels[].name; . == "publication:pending") | tostring),
			(any($labels[].name; . == ("quality-review", "routine-tracking", "source:health-dashboard", "supervisor", "contributor")) | tostring),
			(any($labels[].name; startswith("needs-")) | tostring),
			([$labels[].name | select(. == ("needs-ai-recovery", "needs-dependency", "needs-maintainer-input"))] | join(" ")),
			((any($labels[].name; IN($holds | split(" ")[])) and any($labels[].name; . == $ai)) | tostring),
			(((.assignees // []) | length) | tostring),
			((.updatedAt // .createdAt) | sub("\\.[0-9]+Z$"; "Z") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime | tostring)
		] | join("|")
	' 2>/dev/null
	return 0
}

# Helper: process all issues for one repo. Updates the global
# _LI_* counters (caller accumulates into totals).
#
# Uses global accumulators rather than per-call output vars because
# the outer coordinator needs three counters and one checked count.
#
# DELIMITER CHOICE: '|' — a non-whitespace character that GitHub
# label names cannot contain. Do NOT use @tsv: bash read with
# IFS=$'\t' collapses consecutive tabs because tab is a whitespace
# character in bash's field-splitting rules, so empty fields silently
# disappear and the next field shifts into place, corrupting parses
# on issues with no status labels (tier-only pollution case).
_normalize_label_invariants_for_repo() {
	local slug="$1"
	local triage_cutoff="$2"

	local rows
	rows=$(_fetch_label_invariant_rows "$slug") || return 0
	[[ -n "$rows" ]] || return 0

	local issue_num="" status_list="" tier_list="" has_origin_i="" has_auto="" is_non_task="" created_epoch="" all_status_count=""
	local has_persistent="" has_publication_pending="" has_tracker_identity="" has_needs="" owned_companions="" hold_recovery=""
	local assignee_count="" updated_epoch=""
	while IFS='|' read -r issue_num status_list tier_list has_origin_i has_auto is_non_task created_epoch all_status_count \
		has_persistent has_publication_pending has_tracker_identity has_needs owned_companions hold_recovery \
		assignee_count updated_epoch; do
		[[ "$issue_num" =~ ^[0-9]+$ ]] || continue
		_LI_CHECKED=$((_LI_CHECKED + 1))

		_filter_core_status_labels "$status_list"
		local core_count="${#_LI_FILTERED_STATUS[@]}"

		if [[ "$core_count" -gt 1 ]] &&
			_enforce_status_invariant_one_issue "$issue_num" "$slug" "${_LI_FILTERED_STATUS[@]}"; then
			_LI_STATUS_FIXED=$((_LI_STATUS_FIXED + 1))
		fi

		# GH#38360: single-status rows only; a multi-status row was just
		# repaired by set_issue_status, which owns its companions.
		local companion_mode=""
		local only_blocked="$_LI_BOOL_FALSE"
		[[ "$core_count" -eq 1 && "${_LI_FILTERED_STATUS[0]}" == "$_LI_BLOCKED_STATUS" ]] && only_blocked="$_LI_BOOL_TRUE"
		if [[ "$only_blocked" == "$_LI_BOOL_TRUE" && "$has_needs" == "$_LI_BOOL_FALSE" ]]; then
			companion_mode="bare"
		elif [[ "$only_blocked" == "$_LI_BOOL_TRUE" && "$hold_recovery" == "$_LI_BOOL_TRUE" ]]; then
			# GH#38821: heal maintainer holds the normalizer re-queued as AI recovery.
			companion_mode="hold_heal"
		elif [[ "$core_count" -eq 1 && " ${status_list} " != *" blocked "* && -n "$owned_companions" ]]; then
			# Only an issue with another live lifecycle status left blocked; a
			# status-less issue may carry the label as a deliberate human hold.
			companion_mode="orphan"
		fi
		if [[ -n "$companion_mode" ]] &&
			_enforce_blocked_companion_one_issue "$issue_num" "$slug" "$companion_mode"; then
			_LI_BLOCKED_COMPANION_FIXED=$((_LI_BLOCKED_COMPANION_FIXED + 1))
		fi

		# t19179: unassigned active status idle past the threshold. The listing
		# row is a hint; the helper re-reads the live issue before any write.
		if [[ "$core_count" -eq 1 && "$has_tracker_identity" == "$_LI_BOOL_FALSE" ]] &&
			_orphan_status_row_release "$issue_num" "$slug" "${_LI_FILTERED_STATUS[0]}" "$assignee_count" "$updated_epoch"; then
			_LI_ORPHAN_RELEASED=$((_LI_ORPHAN_RELEASED + 1))
		fi

		local -a tier_arr=()
		if [[ -n "$tier_list" ]]; then
			local _t
			for _t in $tier_list; do
				tier_arr+=("$_t")
			done
		fi

		local tier_count="${#tier_arr[@]}"
		if [[ "$tier_count" -gt 1 ]] &&
			_enforce_tier_invariant_one_issue "$issue_num" "$slug" "${tier_arr[@]}"; then
			_LI_TIER_FIXED=$((_LI_TIER_FIXED + 1))
		fi
		if [[ "$has_auto" == "$_LI_BOOL_TRUE" && "$tier_count" -eq 0 ]] &&
			_backfill_auto_dispatch_tier_one_issue "$issue_num" "$slug"; then
			_LI_TIER_FIXED=$((_LI_TIER_FIXED + 1))
		fi

		# A publication-backed issue is finite, and lifecycle labels prove it is a
		# task. Preserve explicit dashboard/routine identities and ambiguous cases.
		if [[ "$has_persistent" == "$_LI_BOOL_TRUE" &&
			"$has_publication_pending" == "$_LI_BOOL_TRUE" &&
			"$has_tracker_identity" == "$_LI_BOOL_FALSE" ]] &&
			[[ "$has_auto" == "$_LI_BOOL_TRUE" || "$tier_count" -gt 0 || "$all_status_count" -gt 0 ]]; then
			if _enforce_persistent_task_invariant_one_issue "$issue_num" "$slug"; then
				_LI_PERSISTENT_FIXED=$((_LI_PERSISTENT_FIXED + 1))
			fi
		fi

		# Triage-missing count (flag only, no auto-fix). origin:interactive
		# + no tier + no auto-dispatch + no status:* AT ALL (including
		# exception labels like needs-info/verify-failed/stale — an issue
		# in those states is actively managed, not awaiting triage) +
		# no non-task label (routine-tracking/supervisor/etc.) +
		# created >30min ago = maintainer-intended issue not briefed into
		# the dispatch pipeline.
		if [[ "$has_origin_i" == "$_LI_BOOL_TRUE" &&
			-z "$tier_list" &&
			"$has_auto" == "$_LI_BOOL_FALSE" &&
			"$is_non_task" == "$_LI_BOOL_FALSE" &&
			"$all_status_count" == "0" &&
			"$created_epoch" =~ ^[0-9]+$ &&
			"$created_epoch" -lt "$triage_cutoff" ]]; then
			_LI_TRIAGE_MISSING=$((_LI_TRIAGE_MISSING + 1))
		fi
	done <<<"$rows"
	return 0
}

# Helper: write the counter JSON file consumed by t2041 prefetch layer.
_write_label_invariants_counter_file() {
	local counters_dir="${HOME}/.aidevops/cache"
	local hostname_short
	hostname_short=$(hostname -s 2>/dev/null || echo unknown)
	local counters_file="${counters_dir}/pulse-label-invariants.${hostname_short}.json"
	mkdir -p "$counters_dir" 2>/dev/null || true
	{
		printf '{"timestamp": "%s", "checked": %d, "status_fixed": %d, "tier_fixed": %d, "persistent_fixed": %d, "triage_missing": %d, "blocked_companion_fixed": %d, "orphan_released": %d}\n' \
			"$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
			"$_LI_CHECKED" "$_LI_STATUS_FIXED" "$_LI_TIER_FIXED" "$_LI_PERSISTENT_FIXED" "$_LI_TRIAGE_MISSING" \
			"${_LI_BLOCKED_COMPANION_FIXED:-0}" "${_LI_ORPHAN_RELEASED:-0}"
	} >"$counters_file" 2>/dev/null || true
	return 0
}

# t2040: coordinator for the label-invariant pass. Delegates the per-issue
# work to focused helpers so each function stays under the 100-line block
# threshold. Global accumulators (_LI_*) are used instead of per-call
# output vars because the coordinator needs four counters and bash 3.2
# lacks namerefs.
_normalize_label_invariants() {
	local runner_user="$1"
	local repos_json="$2"
	# shellcheck disable=SC2034  # runner_user kept for signature symmetry
	local _unused_runner="$runner_user"

	# Guard: requires the precedence arrays from shared-constants.sh.
	# Silently skip (fail-open) to avoid blocking the pulse on a bootstrap bug.
	if [[ -z "${ISSUE_STATUS_LABEL_PRECEDENCE+x}" || -z "${ISSUE_TIER_LABEL_RANK+x}" ]]; then
		echo "[pulse-wrapper] normalize_label_invariants skipped: precedence arrays not loaded" >>"$LOGFILE"
		return 0
	fi

	# Shared accumulators — reset at start of every pass.
	_LI_CHECKED=0
	_LI_STATUS_FIXED=0
	_LI_TIER_FIXED=0
	_LI_PERSISTENT_FIXED=0
	_LI_TRIAGE_MISSING=0
	_LI_BLOCKED_COMPANION_FIXED=0
	_LI_ORPHAN_RELEASED=0

	local now_epoch
	now_epoch=$(date +%s)
	local triage_cutoff=$((now_epoch - 1800))

	# GH#37568: resume after the repo this pass last started (when the
	# normalization driver supplies the cursor; standalone use keeps order).
	local slug="" li_slugs=""
	li_slugs=$(jq -r '.initialized_repos[] | select(.maintenance != false and .pulse == true and (.local_only // false) == false and .slug != "") | .slug // ""' "$repos_json" || true)
	if declare -F _normalize_rotated_slugs >/dev/null 2>&1; then
		li_slugs=$(_normalize_rotated_slugs label_invariants "$li_slugs")
	fi
	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue
		if declare -F _normalize_mark_repo_started >/dev/null 2>&1; then
			_normalize_mark_repo_started label_invariants "$slug"
		fi
		_normalize_label_invariants_for_repo "$slug" "$triage_cutoff"
	done <<<"$li_slugs"

	echo "[pulse-wrapper] label_invariants: checked=${_LI_CHECKED} status_fixed=${_LI_STATUS_FIXED} tier_fixed=${_LI_TIER_FIXED} persistent_fixed=${_LI_PERSISTENT_FIXED} triage_missing=${_LI_TRIAGE_MISSING} blocked_companion_fixed=${_LI_BLOCKED_COMPANION_FIXED} orphan_released=${_LI_ORPHAN_RELEASED}" >>"$LOGFILE"

	_write_label_invariants_counter_file
	return 0
}
