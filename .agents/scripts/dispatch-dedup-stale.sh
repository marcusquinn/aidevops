#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# dispatch-dedup-stale.sh — Stale assignment recovery subsystem (GH#15060, t2008)
#
# Extracted from dispatch-dedup-helper.sh (GH#18916) to reduce that file below
# the 2000-line simplification gate.
#
# Sourced by dispatch-dedup-helper.sh. Do NOT invoke directly.
#
# Exports:
#   STALE_ASSIGNMENT_THRESHOLD_SECONDS — configurable staleness window (default 600s)
#   _ts_to_epoch <iso8601>             — portable ISO→epoch conversion
#   _is_stale_assignment <issue> <slug> <assignees>
#   _recover_stale_assignment <issue> <slug> <assignees> <reason>

#######################################
# Configurable staleness threshold (seconds).
# GH#17549: Reduced from 30 min to 10 min to match DISPATCH_COMMENT_MAX_AGE.
# Workers either succeed in ~10 min or crash in ~2 min; 30-min TTL wasted
# 28 min of dispatch capacity per crash.
#######################################
STALE_ASSIGNMENT_THRESHOLD_SECONDS="${STALE_ASSIGNMENT_THRESHOLD_SECONDS:-${DISPATCH_COMMENT_MAX_AGE:-600}}"

#######################################
# t2132: Separate threshold for interactive claims.
# Interactive sessions routinely go 30-60+ minutes between actions on an issue
# (writing briefs, reading code, thinking). The default 600s threshold designed
# for headless workers was stripping interactive claims after 10 minutes.
# Default: 7200s (2 hours).
#######################################
INTERACTIVE_STALE_THRESHOLD_SECONDS="${INTERACTIVE_STALE_THRESHOLD_SECONDS:-7200}"

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
	# SCRIPT_DIR is set by the sourcing file (dispatch-dedup-helper.sh)
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
			--body "<!-- stale-recovery-tick:0 (reset: open PR #${_open_pr} detected) -->
Stale recovery tick reset — open PR #${_open_pr} detected (t2008)" \
			2>/dev/null || true
	elif [[ "$_prior_ticks" -ge "$_threshold" ]]; then
		# Threshold reached — escalate and bail out (no normal recovery)
		_stale_recovery_escalate "$issue_number" "$repo_slug" "$stale_assignees" "$reason" "$_threshold" "$_prior_ticks"
		return 0
	else
		# Under threshold — increment tick counter, continue normal recovery
		local _next_tick=$((_prior_ticks + 1))
		gh issue comment "$issue_number" --repo "$repo_slug" \
			--body "<!-- stale-recovery-tick:${_next_tick} -->
Stale recovery tick ${_next_tick}/${_threshold} (t2008)" \
			2>/dev/null || true
	fi
	# ── End stale-recovery escalation check ──────────────────────────────

	_stale_recovery_apply "$issue_number" "$repo_slug" "$stale_assignees" "$reason"
	return 0
}

#######################################
# Stale assignment detection.
#
# When an issue is assigned to a blocking user (another runner), check
# whether that assignment is stale: no active worker process, dispatch
# claim comment is >1h old, and no progress (comments) in the last hour.
#
# If stale, calls _recover_stale_assignment which unassigns the blocking
# users, removes status:queued and status:in-progress labels, posts a
# recovery comment, and returns 0 (stale, safe to re-dispatch).
#
# Args:
#   $1 = issue number
#   $2 = repo slug (owner/repo)
#   $3 = comma-separated blocking assignee logins
# Returns:
#   exit 0 = stale assignment recovered (safe to dispatch)
#   exit 1 = assignment is NOT stale (genuine active claim, block dispatch)
#
# GH#18816: gh comments API failure → fail-CLOSED (return 1, block dispatch).
# jq and timestamp parse failures → fail-OPEN (unreadable ≠ stale).
#######################################

#######################################
# t2132: Resolve the effective stale threshold for an issue.
# Interactive sessions (origin:interactive label) use a longer threshold
# because human-driven sessions routinely go 30-60+ minutes between actions.
#
# t2153 (GH#19424): Also returns the issue's createdAt timestamp so the
# caller can apply the age-floor guard. A single `gh issue view --json
# labels,createdAt` round-trip serves both needs — no extra API call.
#
# Args: $1 = issue number, $2 = repo slug
# Stdout: three lines —
#   1. "is_interactive" ("true"/"false")
#   2. threshold (seconds)
#   3. createdAt (ISO 8601, or empty on API failure)
#######################################
_resolve_stale_threshold() {
	local issue_number="$1"
	local repo_slug="$2"
	local _issue_meta_json _meta_rc=0
	_issue_meta_json=$(gh issue view "$issue_number" --repo "$repo_slug" \
		--json labels,createdAt 2>/dev/null) || _meta_rc=$?

	local is_interactive='false'
	local threshold="$STALE_ASSIGNMENT_THRESHOLD_SECONDS"
	local created_at=''

	if [[ "$_meta_rc" -eq 0 && -n "$_issue_meta_json" ]]; then
		if printf '%s' "$_issue_meta_json" | jq -e '.labels | map(.name) | index("origin:interactive")' >/dev/null 2>&1; then
			is_interactive='true'
			threshold="$INTERACTIVE_STALE_THRESHOLD_SECONDS"
		fi
		created_at=$(printf '%s' "$_issue_meta_json" | jq -r '.createdAt // empty' 2>/dev/null) || created_at=''
	fi
	printf '%s\n%s\n%s\n' "$is_interactive" "$threshold" "$created_at"
	return 0
}

#######################################
# t2153 (GH#19424): Age-floor guard. An issue cannot be "stale" if it is
# itself younger than the staleness threshold. Without this guard, freshly
# created issues with assignees but no comments yet (the common case for
# issues created via issue-sync from TODO entries) fall through to
# _recover_stale_assignment within seconds — both last_dispatch_ts and
# last_activity_ts are empty, so the inner activity-age check is skipped
# and _is_stale_assignment reports stale.
#
# Production case: #19414 was stale-recovered 4 min 53s after creation
# despite carrying origin:interactive (threshold=7200s). The threshold was
# never compared against issue age — only against (non-existent) comment
# timestamps.
#
# Fail-open on missing/unparseable createdAt — the caller's downstream
# fail-CLOSED stance (return 1, block dispatch) handles transient gh errors.
#
# Args: $1 = issue createdAt (ISO 8601, may be empty)
#       $2 = effective threshold seconds
#       $3 = now epoch
# Returns: 0 if too young to be stale; 1 otherwise (caller continues).
#######################################
_issue_too_young_for_staleness() {
	local issue_created_at="$1" effective_threshold="$2" now_epoch="$3"
	[[ -z "$issue_created_at" ]] && return 1
	local epoch
	epoch=$(_ts_to_epoch "$issue_created_at")
	[[ "$epoch" -le 0 ]] && return 1
	[[ "$((now_epoch - epoch))" -lt "$effective_threshold" ]]
}

_is_stale_assignment() {
	local issue_number="$1"
	local repo_slug="$2"
	local blocking_assignees="$3"

	# t2132+t2153: resolve interactive flag, threshold, issue createdAt.
	local is_interactive effective_threshold issue_created_at now_epoch
	read -r is_interactive effective_threshold issue_created_at \
		< <(_resolve_stale_threshold "$issue_number" "$repo_slug" | tr '\n' ' ')
	now_epoch=$(date +%s)
	# t2153 age-floor guard: issue cannot be stale before it could signal.
	_issue_too_young_for_staleness "$issue_created_at" "$effective_threshold" "$now_epoch" && return 1

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

	# t2132 Fix D: Find the most recent dispatch/claim comment.
	# Matches worker dispatch patterns AND interactive session claim pattern.
	# Previously only matched "Dispatching worker|DISPATCH_CLAIM|Worker (PID",
	# which missed the interactive claim comment posted by
	# interactive-session-helper.sh ("Interactive session claimed").
	local last_dispatch_ts=""
	last_dispatch_ts=$(printf '%s' "$comments_json" | jq -r '
		[.[] | select(
			(.body_start | test("Dispatching worker"; "i")) or
			(.body_start | test("DISPATCH_CLAIM"; "i")) or
			(.body_start | test("Worker \\(PID"; "i")) or
			(.body_start | test("Interactive session claimed"; "i"))
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
	# (now_epoch already computed above for the t2153 age-floor guard.)
	local dispatch_epoch activity_epoch

	if [[ -z "$last_dispatch_ts" ]]; then
		# No dispatch comment — check if the last activity is also old
		if [[ -n "$last_activity_ts" ]]; then
			activity_epoch=$(_ts_to_epoch "$last_activity_ts")
			local activity_age=$((now_epoch - activity_epoch))
			if [[ "$activity_age" -lt "$effective_threshold" ]]; then
				# Recent activity but no dispatch comment — could be manual work
				return 1
			fi
		fi
		# No dispatch comment AND no recent activity — stale
		_recover_stale_assignment "$issue_number" "$repo_slug" "$blocking_assignees" "no dispatch claim comment found, no recent activity (threshold=${effective_threshold}s, interactive=${is_interactive})"
		return 0
	fi

	# Dispatch comment exists — check its age against the effective threshold
	dispatch_epoch=$(_ts_to_epoch "$last_dispatch_ts")
	local dispatch_age=$((now_epoch - dispatch_epoch))

	if [[ "$dispatch_age" -lt "$effective_threshold" ]]; then
		# Dispatch claim is recent (< threshold) — honour it
		return 1
	fi

	# Dispatch claim is old. Check if there's been any progress since.
	local activity_age_msg="unknown"
	if [[ -n "$last_activity_ts" ]]; then
		local activity_epoch activity_age
		activity_epoch=$(_ts_to_epoch "$last_activity_ts")
		activity_age=$((now_epoch - activity_epoch))
		activity_age_msg="${activity_age}s"
		if [[ "$activity_age" -lt "$effective_threshold" ]]; then
			# Old dispatch but recent activity — worker may still be alive
			return 1
		fi
	fi

	# Both dispatch claim and last activity are older than threshold — stale
	_recover_stale_assignment "$issue_number" "$repo_slug" "$blocking_assignees" \
		"dispatch claim ${dispatch_age}s old, last activity ${activity_age_msg} old (threshold=${effective_threshold}s, interactive=${is_interactive})"
	return 0
}
