#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-issue-reconcile-stale.sh — Stale assignment recovery helpers (t2375)
#
# Extracted from pulse-issue-reconcile.sh (t2375) to keep that file below the
# 1500-line complexity gate after the cross-runner safety hardening in t2375
# added runner-identity parsing and fail-CLOSED paths. Mirrors the
# dispatch-dedup-stale.sh extraction pattern (GH#18916).
#
# Sourced by pulse-issue-reconcile.sh. Do NOT invoke directly — it relies on
# the orchestrator (pulse-wrapper.sh) having sourced shared-constants.sh and
# worker-lifecycle-common.sh and defined LOGFILE, PULSE_QUEUED_SCAN_LIMIT,
# WORKER_MAX_RUNTIME, and STALE_REASSIGN_UPDATED_THRESHOLD_SECONDS.
#
# Exports:
#   _normalize_clear_status_labels     — Reset a stale issue's labels + assignee
#   _normalize_stale_get_dispatch_info — Read PID, timestamp, runner from dispatch comment
#   _normalize_stale_should_skip_reset — Gate reset decision (t1933 + t2375 cross-runner)
#   _normalize_unassign_stale          — Detect and reset stale runner assignments

# Include guard — prevent double-sourcing.
[[ -n "${_PULSE_ISSUE_RECONCILE_STALE_LOADED:-}" ]] && return 0
_PULSE_ISSUE_RECONCILE_STALE_LOADED=1
# GH#36186: extra audit tokens for the next stale release (set per candidate).
_NORMALIZE_STALE_RELEASE_DETAIL=""

#######################################
# (Phase 12 helper) Reset a single stale issue's labels and assignee.
#
# Removes the active dispatch labels (status:queued, status:in-progress)
# and the runner's assignee from one issue, then marks it status:available
# so the deterministic fill floor can re-dispatch it.
#
# Called by _normalize_unassign_stale once it has confirmed that no worker
# process is actively handling the issue.
#
# Args:
#   $1 issue_num   — numeric GitHub issue number
#   $2 slug        — owner/repo
#   $3 runner_user — GH login to remove as assignee
# Returns: 0 on gh success, non-zero on gh failure
#######################################
_normalize_clear_status_labels() {
	local issue_num="$1"
	local slug="$2"
	local runner_user="$3"

	# t2033: atomic transition to status:available, clearing all sibling
	# core status labels in one edit (not just queued/in-progress).
	declare -F invalidate_footprint_cache_for_issue >/dev/null 2>&1 && invalidate_footprint_cache_for_issue "$issue_num" || true
	set_issue_status "$issue_num" "$slug" "available" \
		--remove-assignee "$runner_user" >/dev/null 2>&1
	return $?
}

#######################################
# GH#35218: post the release audit before any label/assignee mutation, so
# every stale reset is attributable. Returns non-zero when the comment could
# not be persisted; the caller then skips the reset (retried next cycle).
#
# Args:
#   $1 issue_num   — numeric GitHub issue number
#   $2 slug        — owner/repo
#   $3 runner_user — GH login performing the reset
#   $4 detail      — space-separated key=value tokens (no secrets)
#######################################
_normalize_stale_post_release() {
	local issue_num="$1"
	local slug="$2"
	local runner_user="$3"
	local detail="${4:-}"
	local release_ts="" body=""
	release_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	body="<!-- ops:start — workers: skip this comment, it is audit trail not implementation context -->
CLAIM_RELEASED reason=stale_assignment_reset runner=${runner_user} ts=${release_ts}${detail:+ ${detail}}
<!-- ops:end -->"
	gh api "repos/${slug}/issues/${issue_num}/comments" \
		--method POST --field body="$body" >/dev/null 2>&1 || return 1
	return 0
}

#######################################
# GH#35218: this machine's dispatch device ID, read-only. Several hosts can
# share one runner login, so the login alone does not prove a dispatch was
# local. Prints nothing when no valid ID is configured (never creates one).
#######################################
_normalize_stale_local_device_id() {
	local id="${AIDEVOPS_DEVICE_ID:-}"
	local id_file="${AIDEVOPS_DEVICE_ID_FILE:-${HOME}/.aidevops/state/device-id}"
	if [[ -z "$id" && -r "$id_file" ]]; then
		id=$(tr -d '[:space:]' <"$id_file" 2>/dev/null || true)
	fi
	[[ "$id" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$ ]] || id=""
	printf '%s' "$id"
	return 0
}

#######################################
# GH#35218: true when a same-login dispatch ran on this device. A dispatch
# with no device (or the `legacy` placeholder) keeps the pre-device
# behaviour. A recorded device that differs from, or cannot be compared with,
# this device is treated as remote: its PID and log are not visible here.
#######################################
_normalize_stale_dispatch_is_local_device() {
	local dispatch_device="$1"
	[[ -z "$dispatch_device" || "$dispatch_device" == "legacy" ]] && return 0
	local local_device
	local_device=$(_normalize_stale_local_device_id)
	[[ -n "$local_device" && "$local_device" == "$dispatch_device" ]] && return 0
	return 1
}

#######################################
# (Phase 12 helper) Read the Worker PID, dispatch timestamp, and owning
# runner login from the most recent `Dispatching worker` comment on an issue.
#
# t2375: also parses the `**Runner**: <login>` field so the caller can gate
# cross-machine detection on runner identity rather than local PID presence.
# GH#35218: also parses `device=` from the `aidevops:dispatch` marker, since
# one runner login can dispatch from several devices.
# See pulse-dispatch-worker-gates.sh for the comment format.
#
# Outputs four lines to stdout: Worker PID, ISO-8601 created_at, runner
# login, dispatch device. Each is blank if the field is missing from the
# comment (or no dispatch comment exists). All lines may legitimately be
# empty on success — the caller distinguishes by checking which fields are
# populated.
#
# Args:
#   $1 slug       — owner/repo
#   $2 stale_num  — numeric GitHub issue number
# Returns: 0 on success (even if no dispatch comment found);
#          1 on gh api failure (caller should fail-CLOSED — skip reset).
#######################################
_normalize_stale_get_dispatch_info() {
	local slug="$1"
	local stale_num="$2"

	# t2375: capture gh output + exit code separately so we can distinguish
	# "no dispatch comment" (empty output, rc=0) from "gh api failure"
	# (rc!=0). The reactive path in dispatch-dedup-stale.sh:401-405 fails
	# CLOSED on the same signal; match that stance here.
	local gh_output
	local gh_rc=0
	gh_output=$(gh api "repos/${slug}/issues/${stale_num}/comments" \
		--jq '[.[] | select(.body | contains("Dispatching worker"))] | sort_by(.created_at) | last | if . then ((.body | capture("\\*\\*Worker PID\\*\\*: (?<pid>[0-9]+)") // {pid: ""} | .pid), (.created_at | sub("\\.[0-9]+Z$"; "Z")), (.body | capture("\\*\\*Runner\\*\\*: (?<runner>[A-Za-z0-9][A-Za-z0-9-]*)") // {runner: ""} | .runner), (.body | capture("aidevops:dispatch [^>]*device=(?<device>[A-Za-z0-9][A-Za-z0-9._-]*)") // {device: ""} | .device)) else empty end' \
		2>/dev/null) || gh_rc=$?

	if [[ "$gh_rc" -ne 0 ]]; then
		return 1
	fi

	local dispatch_pid=""
	local dispatch_created_at=""
	local dispatch_runner=""
	local dispatch_device=""
	{
		IFS= read -r dispatch_pid
		IFS= read -r dispatch_created_at
		IFS= read -r dispatch_runner
		IFS= read -r dispatch_device
	} <<<"$gh_output"

	printf '%s\n%s\n%s\n%s\n' "$dispatch_pid" "$dispatch_created_at" "$dispatch_runner" "$dispatch_device"
	return 0
}

#######################################
# Reuse the authoritative closing-reference open-PR classifier from reactive
# stale recovery without loading its globals into the pulse wrapper process.
# Output: "PR|kind" when linked evidence exists, empty when absence is proven.
# Returns: 0 on a determinate result, 1 when evidence cannot be established.
#######################################
_normalize_stale_find_open_pr() {
	local issue_number="$1"
	local repo_slug="$2"
	local stale_module_dir="${SCRIPT_DIR:-${BASH_SOURCE[0]%/*}}"
	local stale_module="${stale_module_dir}/dispatch-dedup-stale.sh"

	if declare -F _stale_recovery_find_open_pr >/dev/null 2>&1; then
		_stale_recovery_find_open_pr "$issue_number" "$repo_slug" || return 1
		return 0
	fi
	[[ -r "$stale_module" ]] || return 1
	if ! (
		# shellcheck source=dispatch-dedup-stale.sh
		source "$stale_module"
		_stale_recovery_find_open_pr "$issue_number" "$repo_slug"
	); then
		return 1
	fi
	return 0
}

#######################################
# GH#36186: trusted issue comments (all pages, slurped) for lease liveness.
# Thin wrapper so tests can substitute evidence without a gh stub.
# Args: $1 slug, $2 issue number
#######################################
_normalize_stale_issue_comments() {
	local slug="$1"
	local issue_num="$2"
	gh api "repos/${slug}/issues/${issue_num}/comments?per_page=100" --paginate --slurp 2>/dev/null || return 1
	return 0
}

#######################################
# GH#36186: newest activity epoch of a PR: the later of its updatedAt and its
# head commit date. Prints nothing and returns 1 when it cannot be read.
# Args: $1 slug, $2 PR number
#######################################
_normalize_stale_pr_activity_epoch() {
	local slug="$1"
	local pr_number="$2"
	local pr_json=""
	pr_json=$(gh pr view "$pr_number" --repo "$slug" --json updatedAt,commits 2>/dev/null) || return 1
	printf '%s' "$pr_json" | jq -er '
		[.updatedAt, ((.commits // []) | last | .committedDate?)] |
		map(select(type == "string" and length > 0) | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) |
		max | select(. != null) | floor
	' 2>/dev/null || return 1
	return 0
}

#######################################
# GH#36186: true when a local exact-head continuation for the draft (session
# key built by _prrts_safe_slug) or an issue worker session is still running.
# Args: $1 slug, $2 PR number, $3 issue number
#######################################
_normalize_stale_continuation_process_live() {
	local slug="$1"
	local pr_number="$2"
	local issue_num="$3"
	local safe_slug=""
	safe_slug=$(printf '%s' "$slug" | tr '/:' '--' | sed 's/[][\.*^$+?(){}|]/\\&/g')
	if pgrep -f "session-key[[:space:]]+pr-checkpoint-continuation-${safe_slug}-${pr_number}([^0-9]|$)" >/dev/null 2>&1 ||
		pgrep -f "session-key[[:space:]]+issue-${issue_num}([^0-9]|$)" >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

#######################################
# GH#36186: decide whether a trusted claim or lease still owns the issue: the
# newest DISPATCH_CLAIM/DISPATCH_LEASE line per lease token is non-terminal and
# its expires_at is in the future. Comments by OWNER/MEMBER/COLLABORATOR or by
# this runner count; other authors cannot extend a claim.
# Args: $1 comments JSON (slurped pages or flat), $2 now epoch, $3 self login
# Returns: 0 live lease, 1 none, 2 unreadable evidence
#######################################
_normalize_stale_has_live_lease() {
	local comments="$1"
	local now_epoch="$2"
	local self_login="${3:-}"
	local live=""
	[[ "$now_epoch" =~ ^[0-9]+$ ]] || return 2
	live=$(printf '%s' "$comments" | jq -r --argjson now "$now_epoch" --arg self "$self_login" '
		def field($k): (capture("(^| )" + $k + "=(?<v>[^ ]+)") | .v) // "";
		def trusted_author: ((.author_association // "") as $a |
			$a == "OWNER" or $a == "MEMBER" or $a == "COLLABORATOR") or
			($self != "" and (.user.login // "") == $self);
		[if type == "array" then flatten[] else empty end | objects | select(trusted_author)]
		| sort_by((.created_at // ""), (.id // 0))
		| [.[] | (.body // "") | split("\n")[] | sub("\r$"; "") |
			select(test("^DISPATCH_(CLAIM|LEASE) "))]
		| to_entries
		| reduce .[] as $e ({}; ($e.value | field("lease_token")) as $t |
			.[(if $t == "" then "line-\($e.key)" else $t end)] = $e.value)
		| [.[] | select(field("phase") != "terminal") | field("expires_at")] as $exp
		| if any($exp[]; . != "" and (test("^[0-9]+$") | not)) then "unreadable"
		  else ([$exp[] | (tonumber? // 0) | select(. > $now)] | length > 0)
		  end
	' 2>/dev/null) || return 2
	[[ "$live" == true ]] && return 0
	[[ "$live" == false ]] && return 1
	return 2
}

#######################################
# GH#36186: a worker draft blocks stale reset only while it shows liveness.
# Returns 0 when the draft is provably abandoned (no local continuation
# process, no live lease, no PR activity within max_runtime), 1 otherwise.
# Unreadable evidence fails closed (returns 1).
# Args: $1 issue, $2 slug, $3 PR number, $4 now epoch, $5 max runtime seconds,
#       $6 self login
#######################################
_normalize_stale_draft_is_abandoned() {
	local stale_num="$1"
	local slug="$2"
	local pr_number="$3"
	local now_epoch="$4"
	local max_runtime="$5"
	local self_login="${6:-}"
	local comments="" lease_rc=0 activity_epoch=""
	[[ "$pr_number" =~ ^[1-9][0-9]*$ && "$now_epoch" =~ ^[0-9]+$ && "$max_runtime" =~ ^[0-9]+$ ]] || return 1
	if _normalize_stale_continuation_process_live "$slug" "$pr_number" "$stale_num"; then
		echo "[pulse-wrapper] Stale assignment skip (draft PR #${pr_number} continuation running): #${stale_num} in ${slug}" >>"$LOGFILE"
		return 1
	fi
	if ! comments=$(_normalize_stale_issue_comments "$slug" "$stale_num"); then
		echo "[pulse-wrapper] Stale assignment skip (draft PR #${pr_number} lease lookup fail-closed): #${stale_num} in ${slug}" >>"$LOGFILE"
		return 1
	fi
	_normalize_stale_has_live_lease "$comments" "$now_epoch" "$self_login" || lease_rc=$?
	if [[ "$lease_rc" -ne 1 ]]; then
		echo "[pulse-wrapper] Stale assignment skip (draft PR #${pr_number} lease live or unreadable rc=${lease_rc}): #${stale_num} in ${slug}" >>"$LOGFILE"
		return 1
	fi
	if ! activity_epoch=$(_normalize_stale_pr_activity_epoch "$slug" "$pr_number") ||
		[[ ! "$activity_epoch" =~ ^[0-9]+$ ]]; then
		echo "[pulse-wrapper] Stale assignment skip (draft PR #${pr_number} activity lookup fail-closed): #${stale_num} in ${slug}" >>"$LOGFILE"
		return 1
	fi
	if [[ $((now_epoch - activity_epoch)) -lt "$max_runtime" ]]; then
		echo "[pulse-wrapper] Stale assignment skip (draft PR #${pr_number} active $((now_epoch - activity_epoch))s ago < max_runtime ${max_runtime}s): #${stale_num} in ${slug}" >>"$LOGFILE"
		return 1
	fi
	return 0
}

#######################################
# Decide whether open-PR linkage blocks a stale reset. Ready PRs, protected
# drafts and ambiguous linkage always block. GH#36186: an unprotected worker
# draft (draft_checkpoint) blocks only while it shows liveness; an abandoned
# draft falls through to the remaining checks and the audited release, after
# which dispatch-stalled continues the exact head (its per-head/per-PR fuses
# bound retries).
# Args: $1 issue, $2 slug, $3 now epoch, $4 max runtime, $5 self login
#       ($3-$5 optional; without them every open PR blocks)
# Sets: _NORMALIZE_STALE_RELEASE_DETAIL (extra audit tokens for the release)
# Returns: 0 = block reset, 1 = continue stale evaluation
#######################################
_normalize_stale_open_pr_blocks_reset() {
	local stale_num="$1"
	local slug="$2"
	local now_epoch="${3:-}"
	local max_runtime="${4:-}"
	local self_login="${5:-}"
	local open_pr="" open_pr_number="" open_pr_kind=""
	_NORMALIZE_STALE_RELEASE_DETAIL=""
	if ! open_pr=$(_normalize_stale_find_open_pr "$stale_num" "$slug"); then
		echo "[pulse-wrapper] Stale assignment skip (open-PR lookup fail-closed): #${stale_num} in ${slug} — authoritative linkage unavailable" >>"$LOGFILE"
		return 0
	fi
	if [[ -n "$open_pr" ]]; then
		open_pr_number="${open_pr%%|*}"
		open_pr_kind=""
		[[ "$open_pr" == *"|"* ]] && open_pr_kind="${open_pr#*|}"
		if [[ "$open_pr_kind" == "draft_checkpoint" && -n "$now_epoch" && -n "$max_runtime" ]] &&
			_normalize_stale_draft_is_abandoned "$stale_num" "$slug" "$open_pr_number" \
				"$now_epoch" "$max_runtime" "$self_login"; then
			echo "[pulse-wrapper] Stale assignment candidate (abandoned worker draft PR #${open_pr_number}): #${stale_num} in ${slug} — no live process, lease or PR activity within ${max_runtime}s" >>"$LOGFILE"
			_NORMALIZE_STALE_RELEASE_DETAIL="abandoned_draft_pr=${open_pr_number}"
			return 1
		fi
		echo "[pulse-wrapper] Stale assignment skip (open PR #${open_pr_number}): #${stale_num} in ${slug} — durable implementation handoff exists" >>"$LOGFILE"
		return 0
	fi
	return 1
}

#######################################
# (Phase 12 helper) Decide whether a stale-assigned issue should be skipped
# (worker still active) or reset (worker gone).
#
# Applies checks in order:
#   1. Authoritative open-PR linkage — durable handoff evidence blocks reset,
#      except an abandoned unprotected worker draft (GH#36186).
#   2. Local pgrep — is any process referencing this issue number still running?
#   3. Dispatch-comment ownership gate (t1933 + t2375):
#        - gh-api failure to fetch dispatch info → fail-CLOSED (skip).
#        - dispatch_runner != self_login → cross-machine worker. Skip `ps -p`
#          (PID collisions across machines are meaningless); apply time-based
#          expiry against WORKER_MAX_RUNTIME.
#        - dispatch_runner == self_login → local worker; use `ps -p` against
#          the recorded Worker PID.
#        - dispatch_runner empty but dispatch_pid present → legacy format,
#          fail-CLOSED (cannot verify ownership).
#   4. Worker log recency — local log written in last 10 min (local workers only).
#
# Returns: 0 = skip (worker still active or unverifiable), 1 = reset (worker gone)
#
# Args:
#   $1 stale_num                — numeric GitHub issue number
#   $2 slug                     — owner/repo
#   $3 now_epoch                — current Unix timestamp (date +%s)
#   $4 cross_runner_max_runtime — seconds before cross-runner dispatch expires
#   $5 self_login               — GH login of this runner (for identity gate)
#######################################
_normalize_stale_should_skip_reset() {
	local stale_num="$1"
	local slug="$2"
	local now_epoch="$3"
	local cross_runner_max_runtime="$4"
	local self_login="$5"

	# An open PR linked by GitHub's authoritative closing metadata is durable
	# ownership evidence even after the worker process and dispatch lease expire.
	# Indeterminate linkage fails closed so transient API faults cannot launch a
	# competing implementation. GH#36186: abandoned worker drafts do not block.
	if _normalize_stale_open_pr_blocks_reset "$stale_num" "$slug" "$now_epoch" "$cross_runner_max_runtime" "$self_login"; then
		return 0
	fi

	# Check 1: local worker process still referencing this issue
	if pgrep -f "pulse-reconcile.*[^0-9]${stale_num}([^0-9]|$)" >/dev/null 2>&1 || pgrep -f "#${stale_num}([^0-9]|$)" >/dev/null 2>&1; then
		return 0
	fi

	# t2375: Read dispatch PID, timestamp, and runner from the most recent
	# dispatch comment. Fail-CLOSED on gh api error — match the reactive-path
	# stance in dispatch-dedup-stale.sh:401-405. A transient gh failure is
	# not evidence of staleness.
	local dispatch_info
	local dispatch_info_rc=0
	dispatch_info=$(_normalize_stale_get_dispatch_info "$slug" "$stale_num") || dispatch_info_rc=$?
	if [[ "$dispatch_info_rc" -ne 0 ]]; then
		echo "[pulse-wrapper] Stale assignment skip (gh-api fail-closed): #${stale_num} in ${slug} — cannot fetch dispatch info" >>"$LOGFILE"
		return 0
	fi

	local dispatch_pid=""
	local dispatch_created_at=""
	local dispatch_runner=""
	local dispatch_device=""
	{
		IFS= read -r dispatch_pid
		IFS= read -r dispatch_created_at
		IFS= read -r dispatch_runner
		IFS= read -r dispatch_device
	} <<<"$dispatch_info"

	local dispatch_comment_age=0
	if [[ -n "$dispatch_created_at" ]]; then
		local dispatch_epoch
		dispatch_epoch=$(date -u -d "$dispatch_created_at" '+%s' 2>/dev/null ||
			TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$dispatch_created_at" '+%s' 2>/dev/null ||
			echo "0")
		if [[ "$dispatch_epoch" -gt 0 ]]; then
			dispatch_comment_age=$((now_epoch - dispatch_epoch))
		fi
	fi

	# Check 2: t1933 + t2375 dispatch-ownership gate.
	if [[ -n "$dispatch_pid" ]] && [[ "$dispatch_pid" =~ ^[0-9]+$ ]]; then
		if [[ -z "$dispatch_runner" ]]; then
			# t2375 fail-closed: legacy dispatch comment without **Runner**
			# line. Cannot verify ownership, so skip reset — safer than
			# potentially stealing a live cross-machine worker's assignment.
			echo "[pulse-wrapper] Stale assignment skip (fail-closed legacy format): #${stale_num} in ${slug} — dispatch comment predates Runner field, cannot verify ownership" >>"$LOGFILE"
			return 0
		fi

		if [[ "$dispatch_runner" != "$self_login" ]] ||
			! _normalize_stale_dispatch_is_local_device "$dispatch_device"; then
			# t2375 cross-machine branch: dispatch came from another runner,
			# or (GH#35218) from another device sharing this runner login.
			# PID collision is meaningless across machines — skip `ps -p`
			# and rely on time-based expiry against WORKER_MAX_RUNTIME.
			if [[ "$dispatch_comment_age" -lt "$cross_runner_max_runtime" ]]; then
				echo "[pulse-wrapper] Stale assignment skip (cross-runner guard): #${stale_num} in ${slug} — runner=${dispatch_runner} device=${dispatch_device:-none} vs self=${self_login}, comment age ${dispatch_comment_age}s < max_runtime ${cross_runner_max_runtime}s" >>"$LOGFILE"
				return 0
			fi
			echo "[pulse-wrapper] Stale assignment reset (cross-runner expired): #${stale_num} in ${slug} — runner=${dispatch_runner} device=${dispatch_device:-none} vs self=${self_login}, comment age ${dispatch_comment_age}s >= max_runtime ${cross_runner_max_runtime}s" >>"$LOGFILE"
			# Fall through — reset fires (return 1 below unless Check 3 catches a stray local log).
		else
			# t1933 local branch: dispatch_runner == self_login. PID check
			# is authoritative here. If our own PID is still running, skip;
			# otherwise fall through to Check 3 (local log) and reset.
			if ps -p "$dispatch_pid" >/dev/null 2>&1; then
				return 0
			fi
			echo "[pulse-wrapper] Stale assignment reset candidate (local worker gone): #${stale_num} in ${slug} — dispatch PID ${dispatch_pid} not running, comment age ${dispatch_comment_age}s" >>"$LOGFILE"
		fi
	fi

	# Check 3: worker log recency — log written in last 10 min means worker may still be active
	local worker_log=""
	worker_log=$(aidevops_pulse_worker_log_path "$slug" "$stale_num" 2>/dev/null || true)
	if [[ -f "$worker_log" ]]; then
		local log_mtime
		log_mtime=$(_file_mtime_epoch "$worker_log")
		if [[ $((now_epoch - log_mtime)) -lt 600 ]]; then
			return 0
		fi
	fi

	return 1
}

#######################################
# (Phase 12) Detect and reset stale runner assignments.
#
# Pass 2 of normalize_active_issue_assignments: find issues assigned to
# runner_user with status:queued/in-progress whose updatedAt is older than
# STALE_REASSIGN_UPDATED_THRESHOLD_SECONDS (default 600s = 10 min), verify
# no worker process is handling them (via _normalize_stale_should_skip_reset),
# and reset via _normalize_clear_status_labels so they can be re-dispatched.
#
# t2372: outer time filter lowered from 3600s (1h) to 600s (10 min) so this
# proactive sweep matches the reactive _is_stale_assignment threshold in
# dispatch-dedup-stale.sh. Previously a worker that died between dispatch
# and PR creation stayed assigned for ~60 min before this sweep would even
# consider it as a candidate, because the issue's updatedAt (the dispatch
# comment timestamp) was still within the 1h window. The reactive path
# (Layer 6 dedup) only fires when the pulse retries dispatching the same
# issue, which may not happen for hours under queue pressure.
#
# Inner safeguards in _normalize_stale_should_skip_reset still protect
# live workers (local pgrep, dispatch-comment ownership gate with
# WORKER_MAX_RUNTIME cross-runner expiry, worker log mtime <600s). Lowering
# the outer filter expands the candidate set; the inner guards still gate
# the actual reset. Override via env var:
#
#   STALE_REASSIGN_UPDATED_THRESHOLD_SECONDS=N (default 600)
#
# t1933 + t2375: cross-runner safety is gated on the dispatch comment's
# `**Runner**: <login>` field. When dispatch_runner != self_login, the
# sweep skips local `ps -p` entirely (PID collisions across machines are
# meaningless) and relies on time-based expiry against
# WORKER_MAX_RUNTIME. When dispatch_runner == self_login, local PID and
# log checks are authoritative. Legacy dispatch comments without a
# `**Runner**` line and gh-api failures both fail CLOSED (skip reset) —
# matches the reactive path in dispatch-dedup-stale.sh:401-405.
#
# Args:
#   $1 runner_user              — GH login of the current runner
#   $2 repos_json               — path to repos.json
#   $3 now_epoch                — current Unix timestamp (date +%s)
#   $4 cross_runner_max_runtime — seconds before a cross-runner dispatch is
#                                  considered expired (default: WORKER_MAX_RUNTIME)
# Returns: 0 always (best-effort; logs summary to $LOGFILE)
#######################################
_normalize_unassign_stale() {
	local runner_user="$1"
	local repos_json="$2"
	local now_epoch="$3"
	local cross_runner_max_runtime="$4"

	# t2372: tunable outer-filter age. Default matches the reactive
	# STALE_ASSIGNMENT_THRESHOLD_SECONDS=600 in dispatch-dedup-stale.sh so
	# proactive (this sweep) and reactive (Layer 6 dedup) paths agree on
	# what "stale" means for workers. Validate as int; fall back to 600.
	local _stale_threshold="${STALE_REASSIGN_UPDATED_THRESHOLD_SECONDS:-600}"
	[[ "$_stale_threshold" =~ ^[0-9]+$ ]] || _stale_threshold=600

	local total_reset=0
	local total_candidates=0

	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue
		if ! declare -F repo_allows_pulse_write_actions >/dev/null 2>&1 \
			|| ! repo_allows_pulse_write_actions "$slug"; then
			continue
		fi

		# Find issues assigned to runner_user with active-dispatch labels
		local stale_json
		stale_json=$(gh_issue_list --repo "$slug" --assignee "$runner_user" --state open \
			--json number,labels,updatedAt --limit "$PULSE_QUEUED_SCAN_LIMIT" 2>/dev/null) || stale_json=""
		[[ -n "$stale_json" && "$stale_json" != "null" ]] || continue

		# Filter: has status:queued or status:in-progress, updatedAt older than _stale_threshold
		local stale_issues
		stale_issues=$(printf '%s' "$stale_json" | jq -r --arg cutoff "$((now_epoch - _stale_threshold))" '
			[.[] | select(
				((.labels | map(.name)) | (index("status:queued") or index("status:in-progress")))
				and ((.updatedAt | sub("\\.[0-9]+Z$"; "Z") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) < ($cutoff | tonumber))
			) | .number] | .[]
		' 2>/dev/null) || stale_issues=""
		[[ -n "$stale_issues" ]] || continue

		local stale_num
		while IFS= read -r stale_num; do
			[[ "$stale_num" =~ ^[0-9]+$ ]] || continue
			total_candidates=$((total_candidates + 1))

			if _normalize_stale_should_skip_reset "$stale_num" "$slug" "$now_epoch" "$cross_runner_max_runtime" "$runner_user"; then
				continue
			fi

			# No active worker and all guards passed — reset for re-dispatch.
			# GH#35218: the release audit is persisted first; without it the
			# reset is skipped so no claim is ever released silently.
			local release_device
			release_device=$(_normalize_stale_local_device_id)
			if ! _normalize_stale_post_release "$stale_num" "$slug" "$runner_user" \
				"device=${release_device:-unknown} stale_threshold_s=${_stale_threshold}${_NORMALIZE_STALE_RELEASE_DETAIL:+ ${_NORMALIZE_STALE_RELEASE_DETAIL}}"; then
				echo "[pulse-wrapper] Stale assignment skip (CLAIM_RELEASED not persisted): #${stale_num} in ${slug}" >>"$LOGFILE"
				continue
			fi
			echo "[pulse-wrapper] Stale assignment reset: #${stale_num} in ${slug} — assigned to ${runner_user} with active label but no worker process" >>"$LOGFILE"
			_normalize_clear_status_labels "$stale_num" "$slug" "$runner_user" || true
			total_reset=$((total_reset + 1))
		done <<<"$stale_issues"
	done < <(jq -r '.initialized_repos[] | select((.local_only // false) == false and .slug != "") | .slug // ""' "$repos_json" || true)

	# t2372: always log scan summary so silent runs are visible in pulse log
	# and operators can confirm the sweep is firing per-cycle.
	echo "[pulse-wrapper] Stale assignment scan: threshold=${_stale_threshold}s candidates=${total_candidates} reset=${total_reset}" >>"$LOGFILE"

	return 0
}
