#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# dispatch-dedup-stale.sh — Stale assignment recovery module
#
# Sourced by dispatch-dedup-helper.sh — do NOT execute directly.
# Requires: SCRIPT_DIR, set_issue_status (from shared-constants.sh).
#
# Handles orphaned-assignment deadlock recovery (GH#15060, t2008):
# Detects when a worker assignment is stale (no active process, no recent
# progress) and recovers by unassigning, re-labelling, and posting an audit
# comment so dispatch can proceed to the next qualified runner.

#######################################
# Stale assignment recovery (GH#15060)
#
# When an issue is assigned to a blocking user (another runner), check
# whether that assignment is stale: no active worker process, dispatch
# claim comment is >1h old, and no progress (comments) in the last hour.
#
# If stale, unassign the blocking users, remove status:queued and
# status:in-progress labels (they are lies — no worker is running),
# post a recovery comment for audit trail, and return 0 (stale, safe
# to re-dispatch). The caller then proceeds with dispatch.
#
# This breaks the orphaned-assignment deadlock where a runner goes
# offline and leaves hundreds of issues assigned to it. Without this,
# the dedup guard permanently blocks all dispatch (0 workers, 100%
# failure rate observed in production — 370 issues, 159 PRs stuck).
#
# The 10-minute threshold matches DISPATCH_COMMENT_MAX_AGE (Layer 5).
# GH#17549: Previously 1 hour, creating a dead zone where Layer 5 passed
# (dispatch comment expired) but Layer 6 blocked (assignment still "active").
# Reduced from 30 min to 10 min: workers either succeed in ~10 min or crash
# in ~2 min. The 30-min TTL wasted 28 min of dispatch capacity per crash
# (880 dedup blocks vs 622 dispatches observed). Any legitimate worker
# should produce at least one comment or commit within 10 minutes.
#
# Args:
#   $1 = issue number
#   $2 = repo slug (owner/repo)
#   $3 = comma-separated blocking assignee logins
# Returns:
#   exit 0 = stale assignment recovered (safe to dispatch)
#   exit 1 = assignment is NOT stale (genuine active claim, block dispatch)
#
# GH#18816 design call (2026-04-14): gh comments API failure path decision
#
# Error path classification for _is_stale_assignment:
#
#   gh api comments fetch failure (network, auth, rate limit):
#     → _comments_rc != 0 → return 1 (NOT stale, block dispatch)
#     → FAIL-CLOSED: API failure cannot determine staleness. Block this cycle;
#       the stale check fires again next pulse cycle when the API may be available.
#     → RATIONALE: a transient API failure is not evidence that the assignment is
#       stale. The production deadlock scenario (GH#15060: 370 issues orphaned) was
#       caused by runners going OFFLINE — detectable by old timestamps on the NEXT
#       working pulse cycle, not by comments API failures. Fail-CLOSED delays
#       recovery by at most one pulse cycle (10 min); it does NOT prevent recovery.
#       By contrast, fail-OPEN can dispatch a duplicate worker even when the original
#       worker is actively running (e.g., worker dispatched 2 min ago, comments API
#       blips, recovery fires, second worker dispatched to an issue with an active
#       claim). GH#18816 closed this gap.
#     → CONTEXT: is_assigned() already successfully fetched issue metadata before
#       calling this function. An API failure here indicates a partial degradation
#       (comments endpoint failing while the issue endpoint works). "Unknown" is
#       not "stale" — block until we know.
#
#   jq filter failures (test() regex error, type error on filter):
#     → || last_dispatch_ts="" or || last_activity_ts="" fallbacks
#     → FAIL-OPEN INTENTIONAL: a jq type error on the timestamp extraction does not
#       mean the dispatch comment does not exist; it means we cannot parse it.
#       Treating an unreadable timestamp as absent would permanently block recovery
#       for issues where the comment format changed. The conservative choice here is
#       to keep the previous semantics (treat as no dispatch comment found).
#
#   _ts_to_epoch parse failure:
#     → returns "0" (explicit echo "0" fallback in _ts_to_epoch)
#     → age = now_epoch - 0 = very large number → age > threshold → stale
#     → FAIL-OPEN INTENTIONAL: unreadable timestamp cannot prove recency.
#       An unreadable dispatch timestamp should not permanently block dispatch.
#
# Summary: _is_stale_assignment is a deadlock-recovery function. The gh API
# failure path is now fail-CLOSED (GH#18816) — API failure → block, not recover.
# jq and timestamp parse failures remain fail-OPEN — these indicate format changes,
# not absence of activity. This asymmetry is intentional: network unavailability
# (transient) is distinct from parse errors (structural, affecting all timestamps).
#######################################
STALE_ASSIGNMENT_THRESHOLD_SECONDS="${STALE_ASSIGNMENT_THRESHOLD_SECONDS:-${DISPATCH_COMMENT_MAX_AGE:-600}}" # 10 min (GH#17549: aligned with DISPATCH_COMMENT_MAX_AGE; reduced from 30 min — crash recovery was too slow)

_is_stale_assignment() {
	local issue_number="$1"
	local repo_slug="$2"
	local blocking_assignees="$3"

	# Fetch issue comments to find the most recent dispatch claim and
	# overall activity timestamp. Use --paginate to catch all comments
	# on issues with long histories, but cap with --jq to only extract
	# what we need (timestamp + body snippet for matching).
	#
	# GH#18816: fail-CLOSED on API failure. A transient gh error is NOT evidence
	# that the assignment is stale — block this pulse cycle and retry next cycle.
	local comments_json _comments_rc=0
	comments_json=$(gh api "repos/${repo_slug}/issues/${issue_number}/comments" \
		--jq '[.[] | {created_at: .created_at, author: .user.login, body_start: (.body[:200])}] | sort_by(.created_at) | reverse' \
		2>/dev/null) || _comments_rc=$?

	if [[ "$_comments_rc" -ne 0 ]]; then
		# Cannot fetch comments — cannot determine staleness. Fail-CLOSED:
		# keep the existing assignment protection for this pulse cycle.
		return 1
	fi

	# Find the most recent dispatch/claim comment
	# Matches: "Dispatching worker", "DISPATCH_CLAIM", "Worker (PID"
	local last_dispatch_ts=""
	last_dispatch_ts=$(printf '%s' "$comments_json" | jq -r '
		[.[] | select(
			(.body_start | test("Dispatching worker"; "i")) or
			(.body_start | test("DISPATCH_CLAIM"; "i")) or
			(.body_start | test("Worker \\(PID"; "i"))
		)] | first | .created_at // empty
	' 2>/dev/null) || last_dispatch_ts=""

	# Find the most recent comment of any kind (progress signal)
	local last_activity_ts=""
	last_activity_ts=$(printf '%s' "$comments_json" | jq -r '
		first | .created_at // empty
	' 2>/dev/null) || last_activity_ts=""

	# If no dispatch comment exists at all, the assignment is from a
	# non-worker source (e.g., auto-assignment at issue creation). Treat
	# as stale since there's no worker claim to protect.
	local now_epoch dispatch_epoch activity_epoch
	now_epoch=$(date +%s)

	if [[ -z "$last_dispatch_ts" ]]; then
		# No dispatch comment — check if the last activity is also old
		if [[ -n "$last_activity_ts" ]]; then
			activity_epoch=$(_ts_to_epoch "$last_activity_ts")
			local activity_age=$((now_epoch - activity_epoch))
			if [[ "$activity_age" -lt "$STALE_ASSIGNMENT_THRESHOLD_SECONDS" ]]; then
				# Recent activity but no dispatch comment — could be manual work
				return 1
			fi
		fi
		# No dispatch comment AND no recent activity — stale
		_recover_stale_assignment "$issue_number" "$repo_slug" "$blocking_assignees" "no dispatch claim comment found, no recent activity"
		return 0
	fi

	# Dispatch comment exists — check its age
	dispatch_epoch=$(_ts_to_epoch "$last_dispatch_ts")
	local dispatch_age=$((now_epoch - dispatch_epoch))

	if [[ "$dispatch_age" -lt "$STALE_ASSIGNMENT_THRESHOLD_SECONDS" ]]; then
		# Dispatch claim is recent (< threshold) — honour it
		return 1
	fi

	# Dispatch claim is old. Check if there's been any progress since.
	if [[ -n "$last_activity_ts" ]]; then
		activity_epoch=$(_ts_to_epoch "$last_activity_ts")
		local activity_age=$((now_epoch - activity_epoch))
		if [[ "$activity_age" -lt "$STALE_ASSIGNMENT_THRESHOLD_SECONDS" ]]; then
			# Old dispatch but recent activity — worker may still be alive
			return 1
		fi
	fi

	# Both dispatch claim and last activity are older than threshold — stale
	_recover_stale_assignment "$issue_number" "$repo_slug" "$blocking_assignees" \
		"dispatch claim ${dispatch_age}s old, last activity ${activity_age:-unknown}s old"
	return 0
}

#######################################
# Convert ISO 8601 timestamp to epoch seconds
# Handles both "2026-03-31T23:59:07Z" and "2026-03-31T23:59:07+00:00" formats.
# Bash 3.2 compatible (no date -d on macOS).
# Args: $1 = ISO timestamp
# Returns: epoch seconds on stdout
#######################################
_ts_to_epoch() {
	local ts="$1"
	# macOS date -j -f parses a formatted date string
	if [[ "$(uname)" == "Darwin" ]]; then
		# Strip trailing Z or timezone offset for macOS date parsing
		local clean_ts="${ts%%Z*}"
		clean_ts="${clean_ts%%+*}"
		# GH#17699: TZ=UTC is critical — without it, macOS date interprets
		# the input as local time, making UTC timestamps appear TZ-offset
		# seconds older than they are (e.g. BST/UTC+1 = 3600s too old).
		TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$clean_ts" "+%s" 2>/dev/null || echo "0"
	else
		date -d "$ts" "+%s" 2>/dev/null || echo "0"
	fi
	return 0
}

#######################################
# Load the stale-recovery escalation threshold from config (default 2).
# Sources .agents/configs/dispatch-stale-recovery.conf if present.
# Output: integer threshold on stdout
#######################################
_stale_recovery_load_threshold() {
	local _stale_conf="${SCRIPT_DIR}/../configs/dispatch-stale-recovery.conf"
	if [[ -f "$_stale_conf" ]]; then
		# shellcheck source=/dev/null
		source "$_stale_conf"
	fi
	printf '%s' "${STALE_RECOVERY_THRESHOLD:-2}"
	return 0
}

#######################################
# Count prior non-reset stale-recovery-tick comments on an issue
# (cross-runner counter). Fails open: returns 0 on gh failure.
# Args: $1 = issue number, $2 = repo slug
# Output: integer count on stdout
#######################################
_stale_recovery_count_ticks() {
	local issue_number="$1"
	local repo_slug="$2"
	local _prior_ticks
	_prior_ticks=$(gh api "repos/${repo_slug}/issues/${issue_number}/comments" \
		--jq '[.[] | select(.body | (test("<!-- stale-recovery-tick:[1-9]") and (test("reset") | not)))] | length' \
		2>/dev/null) || _prior_ticks=0
	[[ "$_prior_ticks" =~ ^[0-9]+$ ]] || _prior_ticks=0
	printf '%s' "$_prior_ticks"
	return 0
}

#######################################
# Look up any open PR referencing this issue (counter reset signal).
# A PR means progress is being made — don't escalate yet.
# Args: $1 = issue number, $2 = repo slug
# Output: PR number (or empty) on stdout
#######################################
_stale_recovery_find_open_pr() {
	local issue_number="$1"
	local repo_slug="$2"
	local _open_pr
	_open_pr=$(gh pr list --repo "$repo_slug" --state open \
		--search "#${issue_number} in:body" --limit 1 \
		--json number --jq '.[0].number // empty' 2>/dev/null) || _open_pr=""
	printf '%s' "$_open_pr"
	return 0
}

#######################################
# Escalate to needs-maintainer-review after the stale-recovery threshold
# is reached (t2008).
#
# Unassigns stale workers, clears status labels via set_issue_status, adds
# needs-maintainer-review, and posts an explanatory comment. Emits
# STALE_ESCALATED on stdout for caller pattern matching.
#
# Args:
#   $1 = issue number
#   $2 = repo slug
#   $3 = stale assignees (comma-separated)
#   $4 = reason for latest stale
#   $5 = threshold
#   $6 = prior tick count
# Returns: 0 (always — all gh ops are fire-and-forget)
#######################################
_stale_recovery_escalate() {
	local issue_number="$1"
	local repo_slug="$2"
	local stale_assignees="$3"
	local reason="$4"
	local _threshold="$5"
	local _prior_ticks="$6"

	# Unassign stale workers (still needed to clean up the assignment)
	local _esc_ifs="${IFS:-}"
	local -a _esc_assignee_arr=()
	IFS=',' read -ra _esc_assignee_arr <<<"$stale_assignees"
	IFS="$_esc_ifs"
	# t2033: build remove-assignee flags and clear all core status labels
	# in one atomic edit via set_issue_status (empty target = clear only,
	# pass-through --add-label "needs-maintainer-review").
	local -a _esc_extra=(--add-label "needs-maintainer-review")
	for _esc_assignee in "${_esc_assignee_arr[@]}"; do
		_esc_extra+=(--remove-assignee "$_esc_assignee")
	done
	set_issue_status "$issue_number" "$repo_slug" "" "${_esc_extra[@]}" || true

	# Post escalation comment explaining the suspension
	gh issue comment "$issue_number" --repo "$repo_slug" \
		--body "<!-- stale-recovery-tick:escalated (threshold=${_threshold}) -->
**Stale recovery threshold reached** (t2008)

This issue has been stale-recovered **${_prior_ticks}** consecutive time(s) without producing a PR. Further automated dispatch is suspended until a human reviews the root cause.

Previously assigned to: ${stale_assignees}
Reason for latest stale: ${reason}
Recovery count: ${_prior_ticks} (threshold: ${_threshold})

Marked \`needs-maintainer-review\`. Remove this label after investigating why workers keep failing (wrong brief, unimplementable scope, missing dependency, etc.) to re-enable dispatch.

_This escalation is the \"no-progress fail-safe\" from t2008 (paired with t1986 parent-task guard and t2007 cost circuit breaker)._" \
		2>/dev/null || true
	printf 'STALE_ESCALATED: issue #%s in %s — unassigned %s, applied needs-maintainer-review (threshold %s reached after %s ticks)\n' \
		"$issue_number" "$repo_slug" "$stale_assignees" "$_threshold" "$_prior_ticks"
	return 0
}

#######################################
# Apply normal stale recovery: unassign stale users, transition to
# status:available, post the audit comment with WORKER_SUPERSEDED marker.
#
# t2033: atomically unassign all stale users and transition to status:available
# via set_issue_status — previously two separate gh edits could race and leave
# conflicting labels (e.g., status:available + status:queued on #18444).
#
# The WORKER_SUPERSEDED marker (t1955) is a structured HTML comment that
# workers can detect before creating PRs. If a worker's runner login matches
# the superseded runner, it knows its assignment was revoked and should
# abort or re-claim.
#
# Args:
#   $1 = issue number
#   $2 = repo slug
#   $3 = stale assignees (comma-separated)
#   $4 = reason
# Returns: 0 (always)
#######################################
_stale_recovery_apply() {
	local issue_number="$1"
	local repo_slug="$2"
	local stale_assignees="$3"
	local reason="$4"

	local saved_ifs="${IFS:-}"
	local -a assignee_arr=()
	IFS=',' read -ra assignee_arr <<<"$stale_assignees"
	IFS="$saved_ifs"

	local -a _recov_extra=()
	local assignee
	for assignee in "${assignee_arr[@]}"; do
		[[ -n "$assignee" ]] && _recov_extra+=(--remove-assignee "$assignee")
	done
	set_issue_status "$issue_number" "$repo_slug" "available" "${_recov_extra[@]}" || true

	local _now_ts
	_now_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	gh issue comment "$issue_number" --repo "$repo_slug" \
		--body "<!-- WORKER_SUPERSEDED runners=${stale_assignees} ts=${_now_ts} -->
**Stale assignment recovered** (GH#15060)

Previously assigned to: ${stale_assignees}
Reason: ${reason}
Threshold: ${STALE_ASSIGNMENT_THRESHOLD_SECONDS}s

The assigned runner had no active worker process and produced no progress within the threshold. Unassigned and relabeled \`status:available\` for re-dispatch.

_This recovery prevents the orphaned-assignment deadlock where offline runners permanently block all dispatch._" 2>/dev/null || true

	printf 'STALE_RECOVERED: issue #%s in %s — unassigned %s (%s)\n' \
		"$issue_number" "$repo_slug" "$stale_assignees" "$reason"
	return 0
}

#######################################
# Recover a stale assignment.
#
# Decision flow (t2008 escalation check):
#   1. Load threshold from config (default 2).
#   2. Count prior non-reset tick comments.
#   3. Look up any open PR referencing this issue.
#      - If an open PR exists: reset tick counter (progress is being made),
#        continue to normal recovery.
#      - Else if prior_ticks >= threshold: escalate to needs-maintainer-review
#        and return immediately (no normal recovery).
#      - Else: increment the tick counter and continue to normal recovery.
#   4. Normal recovery: unassign stale users, set status:available, post audit.
#
# Args:
#   $1 = issue number
#   $2 = repo slug
#   $3 = stale assignees (comma-separated)
#   $4 = reason
#######################################
_recover_stale_assignment() {
	local issue_number="$1"
	local repo_slug="$2"
	local stale_assignees="$3"
	local reason="$4"

	# ── Stale-recovery escalation check (t2008) ──────────────────────────
	# After STALE_RECOVERY_THRESHOLD consecutive recoveries without a PR, stop
	# resetting to status:available and apply needs-maintainer-review instead.
	# Counter is stored as structured comment markers for cross-runner correctness.
	# Config: .agents/configs/dispatch-stale-recovery.conf
	local _threshold _prior_ticks _open_pr
	_threshold=$(_stale_recovery_load_threshold)
	_prior_ticks=$(_stale_recovery_count_ticks "$issue_number" "$repo_slug")
	_open_pr=$(_stale_recovery_find_open_pr "$issue_number" "$repo_slug")

	if [[ -n "$_open_pr" ]]; then
		# Open PR exists — counter resets; post a reset marker and allow normal recovery
		gh issue comment "$issue_number" --repo "$repo_slug" \
			--body "<!-- stale-recovery-tick:0 (reset: open PR #${_open_pr} detected) -->" \
			2>/dev/null || true
	elif [[ "$_prior_ticks" -ge "$_threshold" ]]; then
		# Threshold reached — escalate and bail out (no normal recovery)
		_stale_recovery_escalate "$issue_number" "$repo_slug" "$stale_assignees" "$reason" "$_threshold" "$_prior_ticks"
		return 0
	else
		# Under threshold — increment tick counter, continue normal recovery
		local _next_tick=$((_prior_ticks + 1))
		gh issue comment "$issue_number" --repo "$repo_slug" \
			--body "<!-- stale-recovery-tick:${_next_tick} -->" \
			2>/dev/null || true
	fi
	# ── End stale-recovery escalation check ──────────────────────────────

	_stale_recovery_apply "$issue_number" "$repo_slug" "$stale_assignees" "$reason"
	return 0
}
