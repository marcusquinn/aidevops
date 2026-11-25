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
#                                        (per-repo listing; fallback pass)
#   _normalize_unassign_stale_search   — Same sweep from one search, every
#                                        normalize run (GH#40231)
#   _normalize_claim_recovery_every_run — Search sweep + claim-release drains,
#                                        run before the listing passes
#   _normalize_stale_per_repo_backstop_due — When the per-repo pass still runs
#   _normalize_stale_recover_orphaned_self_claim — Guarded is-assigned recovery
#                                        for orphaned self-device claims (GH#40204)
#   _normalize_unassign_available_stale — Release stale assignees on status:available issues (GH#39327)

# Include guard — prevent double-sourcing.
[[ -n "${_PULSE_ISSUE_RECONCILE_STALE_LOADED:-}" ]] && return 0
_PULSE_ISSUE_RECONCILE_STALE_LOADED=1
# GH#36186: extra audit tokens for the next stale release (set per candidate).
_NORMALIZE_STALE_RELEASE_DETAIL=""
# GH#40204: why _normalize_stale_should_skip_reset last skipped a candidate
# (empty when the skip reason is not used by orphaned-claim recovery).
_NORMALIZE_STALE_SKIP_REASON=""

# GH#36553: local-first recovery; the existing close command owns all GH guards.
_normalize_stale_close_pending_checkpoint_leases() {
	local module="${BASH_SOURCE[0]%/*}/terminal_lease_recovery.py"
	local summary=""
	summary=$(python3 "$module" drain) || return 1
	printf '[pulse-wrapper] Pending checkpoint leases: %s\n' "$summary" >>"$LOGFILE"
	return 0
}

# GH#37344: replay terminal claim releases that GitHub admission deferred. The
# consumer revalidates authority, claim, owner and worker liveness per row and
# is bounded per cycle; deferral keeps the private retry row for a later pass.
_normalize_deferred_claim_releases() {
	local helper="${BASH_SOURCE[0]%/*}/headless-runtime-release-retry.sh"
	local summary=""
	[[ -x "$helper" ]] || return 0
	summary=$(timeout 120 "$helper" drain 2>/dev/null) || return 0
	[[ "$summary" == "candidates=0 resolved=0 retained=0" ]] ||
		printf '[pulse-wrapper] Deferred claim releases: %s\n' "$summary" >>"$LOGFILE"
	return 0
}

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
#          1 on gh api or parse failure (caller should fail-CLOSED — skip reset).
#######################################
_normalize_stale_get_dispatch_info() {
	local slug="$1"
	local stale_num="$2"

	# t2375: separate "no dispatch comment" (empty output, rc=0) from a
	# fetch or parse failure (rc=1). The reactive path in
	# dispatch-dedup-stale.sh fails CLOSED on the same signal.
	# GH#39993: read every comment page. An unpaginated call returns only the
	# oldest 30 comments, so on long issues an old dispatch looked expired and
	# a live same-login worker on another device was reset.
	local comment_pages=""
	comment_pages=$(_normalize_stale_issue_comments "$slug" "$stale_num") || return 1

	local gh_output=""
	gh_output=$(printf '%s' "$comment_pages" | jq -r \
		'[.[] | .[]? | select((.body // "") | contains("Dispatching worker"))] | sort_by(.created_at) | last | if . then ((.body | capture("\\*\\*Worker PID\\*\\*: (?<pid>[0-9]+)") // {pid: ""} | .pid), (.created_at | sub("\\.[0-9]+Z$"; "Z")), (.body | capture("\\*\\*Runner\\*\\*: (?<runner>[A-Za-z0-9][A-Za-z0-9-]*)") // {runner: ""} | .runner), (.body | capture("aidevops:dispatch [^>]*device=(?<device>[A-Za-z0-9][A-Za-z0-9._-]*)") // {device: ""} | .device)) else empty end' \
		2>/dev/null) || return 1

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
# GH#36186: issue comments (all pages, slurped) for lease liveness and, since
# GH#39993, for the latest dispatch comment.
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
	_NORMALIZE_STALE_SKIP_REASON=""

	# An authoritatively linked open PR is durable ownership evidence even after
	# the worker and lease expire; indeterminate linkage fails closed.
	# GH#36186: abandoned worker drafts do not block.
	if _normalize_stale_open_pr_blocks_reset "$stale_num" "$slug" "$now_epoch" "$cross_runner_max_runtime" "$self_login"; then
		_NORMALIZE_STALE_SKIP_REASON="open_pr"
		return 0
	fi

	# Check 1: local worker process still referencing this issue
	if pgrep -f "pulse-reconcile.*[^0-9]${stale_num}([^0-9]|$)" >/dev/null 2>&1 || pgrep -f "#${stale_num}([^0-9]|$)" >/dev/null 2>&1; then
		_NORMALIZE_STALE_SKIP_REASON="local_process"
		return 0
	fi

	# t2375: read PID, timestamp and runner from the latest dispatch comment.
	# Fail-CLOSED on gh api error: a transient failure is not staleness.
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
				_NORMALIZE_STALE_SKIP_REASON="worker_pid_alive"
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
# GH#40204: orphaned self-device claim recovery.
#
# A worker whose exit-path CLAIM_RELEASED write fails (rest-gate deferral,
# network or host IPC outage) leaves its issue status:in-progress and assigned
# to this runner. The sweep above then skips it while any surviving process
# still names "#N" (for example a detached runtime subshell of the dead
# worker) or while the recorded PID has been reused. Candidate listing
# excludes status:in-progress, so the guarded is-assigned recovery never ran.
#
# These helpers prove the claim is this device's and its worker is gone, then
# delegate the decision and audit to `dispatch-dedup-helper.sh is-assigned`,
# which keeps its open-PR, branch-activity, issue-activity and interactive
# fences. No staleness rule is reimplemented here.
#######################################

# True when a live process for session issue-N leads its own process group:
# the registered headless runtime of a live worker. A surviving subshell of a
# dead worker keeps the dead leader's PGID, so it does not count. Local only.
# Args: $1 issue number
_normalize_stale_session_leader_live() {
	local issue_num="$1"
	local pids="" pid="" pgid=""
	pids=$(pgrep -f "session-key[[:space:]]+issue-${issue_num}([^0-9]|$)" 2>/dev/null) || pids=""
	while IFS= read -r pid; do
		[[ "$pid" =~ ^[0-9]+$ ]] || continue
		pgid=$(ps -o pgid= -p "$pid" 2>/dev/null) || pgid=""
		pgid="${pgid//[[:space:]]/}"
		[[ "$pgid" == "$pid" ]] && return 0
	done <<<"$pids"
	return 1
}

# True when PID is running and its command line still names the issue, so a
# reused PID is not mistaken for the registered worker.
# Args: $1 PID, $2 issue number
_normalize_stale_worker_pid_owns_issue() {
	local pid="$1"
	local issue_num="$2"
	local cmd=""
	local issue_re="(issue-|#)${issue_num}([^0-9]|$)"
	[[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
	cmd=$(ps -o command= -p "$pid" 2>/dev/null) || return 1
	[[ "$cmd" =~ $issue_re ]] && return 0
	return 1
}

# Claim evidence from trusted comments (slurped pages or flat array):
# "pid|dispatch_runner|dispatch_device|lease_device|claim_runner" from the
# newest `Dispatching worker` comment and the newest DISPATCH_CLAIM/LEASE line.
# Args: $1 comments JSON, $2 self login
_normalize_stale_self_claim_evidence() {
	local comments="$1"
	local self_login="$2"
	printf '%s' "$comments" | jq -r --arg self "$self_login" '
		def trusted: ((.author_association // "") as $a |
			$a == "OWNER" or $a == "MEMBER" or $a == "COLLABORATOR") or
			($self != "" and (.user.login // "") == $self);
		def grab($re): ((capture($re) // {v: ""}) | .v);
		[if type == "array" then flatten[] else empty end | objects | select(trusted)]
		| sort_by((.created_at // ""), (.id // 0)) as $c
		| (([$c[] | (.body // "") | select(contains("Dispatching worker"))] | last) // "") as $d
		| [$c[] | (.body // "") | split("\n")[] | sub("\r$"; "")
			| select(test("^DISPATCH_(CLAIM|LEASE) "))] as $leases
		| (($leases | last) // "") as $l
		| (([$leases[] | select(startswith("DISPATCH_CLAIM "))] | last) // "") as $cl
		| [($d | grab("\\*\\*Worker PID\\*\\*: (?<v>[0-9]+)")),
		   ($d | grab("\\*\\*Runner\\*\\*: (?<v>[A-Za-z0-9][A-Za-z0-9-]*)")),
		   ($d | grab("aidevops:dispatch [^>]*device=(?<v>[A-Za-z0-9][A-Za-z0-9._-]*)")),
		   ($l | grab("(^| )device=(?<v>[A-Za-z0-9][A-Za-z0-9._-]*)")),
		   ($cl | grab("(^| )runner=(?<v>[A-Za-z0-9][A-Za-z0-9-]*)"))]
		| join("|")
	' 2>/dev/null || return 1
	return 0
}

# Local, API-free prefilter: 0 when the candidate may be an orphaned claim of
# this device (no live session leader, no recent worker log), 1 otherwise.
# Args: $1 issue, $2 slug, $3 now epoch
_normalize_stale_orphan_local_prefilter() {
	local stale_num="$1"
	local slug="$2"
	local now_epoch="$3"
	[[ -n "$(_normalize_stale_local_device_id)" ]] || return 1
	_normalize_stale_session_leader_live "$stale_num" && return 1
	local worker_log="" log_mtime=0
	worker_log=$(aidevops_pulse_worker_log_path "$slug" "$stale_num" 2>/dev/null || true)
	if [[ -n "$worker_log" && -f "$worker_log" ]] && declare -F _file_mtime_epoch >/dev/null 2>&1; then
		log_mtime=$(_file_mtime_epoch "$worker_log")
		[[ "$log_mtime" =~ ^[0-9]+$ ]] || return 1
		[[ $((now_epoch - log_mtime)) -lt 600 ]] && return 1
	fi
	return 0
}

# Prove the claim is this runner's and device's, its lease has expired and
# its registered worker PID is gone; then run the guarded is-assigned path.
# Args: $1 issue, $2 slug, $3 now epoch, $4 self login, $5 dedup helper path
# Returns: 0 recovered (STALE_RECOVERED), 1 otherwise (no mutation by us)
_normalize_stale_recover_orphaned_self_claim() {
	local stale_num="$1"
	local slug="$2"
	local now_epoch="$3"
	local self_login="$4"
	local dedup_helper="$5"
	local local_device="" comments="" evidence="" lease_rc=0 output=""
	local pid="" runner="" dispatch_device="" lease_device="" claim_runner=""
	[[ -n "$self_login" && -n "$dedup_helper" && -x "$dedup_helper" ]] || return 1
	local_device=$(_normalize_stale_local_device_id)
	[[ -n "$local_device" ]] || return 1
	if ! comments=$(_normalize_stale_issue_comments "$slug" "$stale_num"); then
		echo "[pulse-wrapper] Orphaned self claim skip (comment lookup fail-closed): #${stale_num} in ${slug}" >>"$LOGFILE"
		return 1
	fi
	evidence=$(_normalize_stale_self_claim_evidence "$comments" "$self_login") || return 1
	IFS='|' read -r pid runner dispatch_device lease_device claim_runner <<<"$evidence"
	runner="${runner:-$claim_runner}"
	[[ "$runner" == "$self_login" && "$lease_device" == "$local_device" ]] || return 1
	[[ -z "$dispatch_device" || "$dispatch_device" == "$local_device" ]] || return 1
	_normalize_stale_has_live_lease "$comments" "$now_epoch" "$self_login" || lease_rc=$?
	[[ "$lease_rc" -eq 1 ]] || return 1
	if [[ -n "$pid" ]] && _normalize_stale_worker_pid_owns_issue "$pid" "$stale_num"; then
		return 1
	fi
	output=$("$dedup_helper" is-assigned "$stale_num" "$slug" "$self_login" 2>/dev/null) || true
	echo "[pulse-wrapper] Orphaned self claim check: #${stale_num} in ${slug} — device=${local_device} pid=${pid:-none} lease expired, worker gone; is-assigned: ${output%%$'\n'*}" >>"$LOGFILE"
	[[ "$output" == *STALE_RECOVERED* ]] && return 0
	return 1
}

# Per-sweep orphan counters, reset by _normalize_unassign_stale.
_NORMALIZE_ORPHAN_CHECKED=0
_NORMALIZE_ORPHAN_RECOVERED=0

# Sweep hook after _normalize_stale_should_skip_reset skipped a candidate:
# only process-match and live-PID skips qualify, the local prefilter runs
# before any API read, and comment-reading checks are capped per sweep.
# Args: $1 issue, $2 slug, $3 now epoch, $4 self login, $5 dedup helper,
#       $6 per-sweep cap
# Returns: 0 recovered, 1 otherwise
_normalize_stale_try_orphan_recovery() {
	local stale_num="$1"
	local slug="$2"
	local now_epoch="$3"
	local self_login="$4"
	local dedup_helper="$5"
	local cap="$6"
	case "$_NORMALIZE_STALE_SKIP_REASON" in
	local_process | worker_pid_alive) ;;
	*) return 1 ;;
	esac
	[[ -n "$dedup_helper" && "$_NORMALIZE_ORPHAN_CHECKED" -lt "$cap" ]] || return 1
	_normalize_stale_orphan_local_prefilter "$stale_num" "$slug" "$now_epoch" || return 1
	_NORMALIZE_ORPHAN_CHECKED=$((_NORMALIZE_ORPHAN_CHECKED + 1))
	_normalize_stale_recover_orphaned_self_claim "$stale_num" "$slug" "$now_epoch" \
		"$self_login" "$dedup_helper" || return 1
	_NORMALIZE_ORPHAN_RECOVERED=$((_NORMALIZE_ORPHAN_RECOVERED + 1))
	return 0
}

# Gate, audit and reset one stale candidate. Shared by the per-repo pass and
# the search sweep (GH#40231) so both apply identical guards.
# Args: $1 issue, $2 slug, $3 now epoch, $4 cross-runner max runtime,
#       $5 runner login, $6 dedup helper (may be empty), $7 orphan cap,
#       $8 stale threshold seconds (audit detail only)
# Returns: 0 reset, 1 kept (worker live, unverifiable, or audit not persisted)
_normalize_stale_process_candidate() {
	local stale_num="$1"
	local slug="$2"
	local now_epoch="$3"
	local cross_runner_max_runtime="$4"
	local runner_user="$5"
	local dedup_helper="$6"
	local orphan_cap="$7"
	local stale_threshold="$8"
	local release_device=""

	if _normalize_stale_should_skip_reset "$stale_num" "$slug" "$now_epoch" "$cross_runner_max_runtime" "$runner_user"; then
		# GH#40204: a process match or live recorded PID is not proof that
		# this device's worker still owns the claim.
		_normalize_stale_try_orphan_recovery "$stale_num" "$slug" "$now_epoch" \
			"$runner_user" "$dedup_helper" "$orphan_cap" || true
		return 1
	fi

	# No active worker and all guards passed — reset for re-dispatch.
	# GH#35218: the release audit is persisted first; without it the reset is
	# skipped so no claim is ever released silently.
	release_device=$(_normalize_stale_local_device_id)
	if ! _normalize_stale_post_release "$stale_num" "$slug" "$runner_user" \
		"device=${release_device:-unknown} stale_threshold_s=${stale_threshold}${_NORMALIZE_STALE_RELEASE_DETAIL:+ ${_NORMALIZE_STALE_RELEASE_DETAIL}}"; then
		echo "[pulse-wrapper] Stale assignment skip (CLAIM_RELEASED not persisted): #${stale_num} in ${slug}" >>"$LOGFILE"
		return 1
	fi
	echo "[pulse-wrapper] Stale assignment reset: #${stale_num} in ${slug} — assigned to ${runner_user} with active label but no worker process" >>"$LOGFILE"
	_normalize_clear_status_labels "$stale_num" "$slug" "$runner_user" || true
	return 0
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
#   $5 dedup_helper             — optional dispatch-dedup-helper.sh path; enables
#                                  GH#40204 orphaned self-device claim recovery
# Env: AIDEVOPS_ORPHANED_SELF_CLAIM_CAP (default 5) comment-reading orphan
#      checks per cycle (live same-device workers are filtered locally first)
# Returns: 0 always (best-effort; logs summary to $LOGFILE)
#######################################
_normalize_unassign_stale() {
	local runner_user="$1"
	local repos_json="$2"
	local now_epoch="$3"
	local cross_runner_max_runtime="$4"
	local dedup_helper="${5:-}"
	local orphan_cap="${AIDEVOPS_ORPHANED_SELF_CLAIM_CAP:-5}"
	[[ "$orphan_cap" =~ ^[0-9]+$ ]] || orphan_cap=5
	_NORMALIZE_ORPHAN_CHECKED=0
	_NORMALIZE_ORPHAN_RECOVERED=0

	# t2372: tunable outer-filter age. Default matches the reactive
	# STALE_ASSIGNMENT_THRESHOLD_SECONDS=600 in dispatch-dedup-stale.sh so
	# proactive (this sweep) and reactive (Layer 6 dedup) paths agree on
	# what "stale" means for workers. Validate as int; fall back to 600.
	local _stale_threshold="${STALE_REASSIGN_UPDATED_THRESHOLD_SECONDS:-600}"
	[[ "$_stale_threshold" =~ ^[0-9]+$ ]] || _stale_threshold=600

	local total_reset=0
	local total_candidates=0

	# GH#37568: resume after the repo this pass last started (when the
	# normalization driver supplies the cursor; standalone use keeps order).
	local stale_slugs=""
	stale_slugs=$(jq -r '.initialized_repos[] | select((.local_only // false) == false and .slug != "") | .slug // ""' "$repos_json" || true)
	if declare -F _normalize_rotated_slugs >/dev/null 2>&1; then
		stale_slugs=$(_normalize_rotated_slugs unassign_stale "$stale_slugs")
	fi

	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue
		if declare -F _normalize_mark_repo_started >/dev/null 2>&1; then
			_normalize_mark_repo_started unassign_stale "$slug"
		fi
		if ! declare -F repo_allows_pulse_write_actions >/dev/null 2>&1 \
			|| ! repo_allows_pulse_write_actions "$slug"; then
			continue
		fi

		# Find issues assigned to runner_user with active-dispatch labels
		local stale_json="" _listing_rc=0
		stale_json=$(_normalize_repo_listing "$slug") || _listing_rc=$?
		if [[ "$_listing_rc" -eq 2 ]]; then
			stale_json=$(gh_issue_list --repo "$slug" --assignee "$runner_user" --state open \
				--json number,labels,updatedAt --limit "$PULSE_QUEUED_SCAN_LIMIT" 2>/dev/null) || stale_json=""
		elif [[ "$_listing_rc" -eq 0 ]]; then
			# Shared listing is unfiltered: keep only issues assigned to this runner.
			stale_json=$(printf '%s' "$stale_json" | jq -c --arg u "$runner_user" --argjson n "$PULSE_QUEUED_SCAN_LIMIT" \
				'[.[] | select(.assignees // [] | map(.login) | index($u))] | .[0:$n]' 2>/dev/null) || stale_json=""
		else
			stale_json=""
		fi
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
			if _normalize_stale_process_candidate "$stale_num" "$slug" "$now_epoch" \
				"$cross_runner_max_runtime" "$runner_user" "$dedup_helper" "$orphan_cap" "$_stale_threshold"; then
				total_reset=$((total_reset + 1))
			fi
		done <<<"$stale_issues"
	done <<<"$stale_slugs"

	# t2372: always log scan summary so silent runs are visible in pulse log
	# and operators can confirm the sweep is firing per-cycle.
	echo "[pulse-wrapper] Stale assignment scan: threshold=${_stale_threshold}s candidates=${total_candidates} reset=${total_reset} orphan_checked=${_NORMALIZE_ORPHAN_CHECKED} orphan_recovered=${_NORMALIZE_ORPHAN_RECOVERED}" >>"$LOGFILE"

	return 0
}

#######################################
# GH#40231: search-driven stale sweep.
#
# The per-repo pass above lists every pulse repo, so on large fleets it shared
# one stage budget with four other listing passes and was killed before it
# reached most repos: dead workers' claims stayed status:in-progress for
# hours. One search finds this runner's stale active claims in every repo;
# each candidate then goes through the same gate and audited reset.
#
# Search can lag the live issue, so every candidate is re-read before any
# gate. Search can also omit repos the token cannot search (for example an
# org whose SSO has not authorised it), so the caller keeps the per-repo pass
# as a slower backstop.
#######################################

# ISO-8601 UTC for an epoch (portable via jq). Prints nothing on bad input.
_normalize_stale_epoch_iso() {
	local epoch="$1"
	[[ "$epoch" =~ ^[0-9]+$ ]] || return 1
	jq -rn --argjson e "$epoch" '$e | todate' 2>/dev/null || return 1
	return 0
}

# jq definitions shared by the search sweep. Callers pass --arg u (runner
# login), --arg queued and --arg in_progress (active status label names) and
# --argjson cutoff (epoch). A stale claim is an issue, actively labelled,
# assigned to the runner and last updated before the cutoff.
# shellcheck disable=SC2016  # $names are jq variables, expanded by jq
_NORMALIZE_STALE_SEARCH_JQ_DEFS='
	def updated_epoch: try (.updated_at | fromdateiso8601) catch 9999999999;
	def stale_claim:
		(.pull_request == null)
		and ([.labels[]?.name] | (index($queued) or index($in_progress)))
		and ([.assignees[]?.login | ascii_downcase] | index($u | ascii_downcase))
		and (updated_epoch < $cutoff);
'

# True when the live issue is still an open stale claim of the runner.
# Unreadable issues fail closed.
# Args: $1 issue, $2 slug, $3 runner login, $4 cutoff epoch
_normalize_stale_search_live_recheck() {
	local stale_num="$1"
	local slug="$2"
	local runner_user="$3"
	local cutoff="$4"
	local issue_json=""
	issue_json=$(gh api "repos/${slug}/issues/${stale_num}" 2>/dev/null) || return 1
	printf '%s' "$issue_json" | jq -e --arg u "$runner_user" --argjson cutoff "$cutoff" \
		--arg queued status:queued --arg in_progress status:in-progress \
		"${_NORMALIZE_STALE_SEARCH_JQ_DEFS}"'(.state == "open") and stale_claim' >/dev/null 2>&1 || return 1
	return 0
}

# "slug|number" rows (repos.json slug spelling), oldest update first, for
# search items in non-local repos.json repos that still look stale.
# Args: $1 search JSON, $2 repos.json path, $3 runner login, $4 cutoff epoch
_normalize_stale_search_rows() {
	local result="$1"
	local repos_json="$2"
	local runner_user="$3"
	local cutoff="$4"
	printf '%s' "$result" | jq -r --slurpfile repos "$repos_json" \
		--arg u "$runner_user" --argjson cutoff "$cutoff" \
		--arg queued status:queued --arg in_progress status:in-progress \
		"${_NORMALIZE_STALE_SEARCH_JQ_DEFS}"'
		([$repos[0].initialized_repos[]?
			| select((.local_only // false) == false and ((.slug | strings | length) > 0))
			| {key: (.slug | ascii_downcase), value: .slug}] | from_entries) as $known
		| [.items[]?
			| (.repository_url | tostring | split("/") | .[-2:] | join("/") | ascii_downcase) as $k
			| select(($known[$k] != null) and stale_claim)
			| {t: updated_epoch, row: "\($known[$k])|\(.number)"}]
		| sort_by(.t) | .[].row
	' 2>/dev/null || return 1
	return 0
}

#######################################
# Sweep this runner's stale active claims from one search.
#
# Candidates with a live same-device session leader are skipped before any
# API read (a live registered worker always keeps its claim). At most
# AIDEVOPS_STALE_SEARCH_MAX_CANDIDATES (default 20) other candidates are
# checked per run, oldest update first; the rest wait for the next run.
#
# Args: $1 runner login, $2 repos.json, $3 now epoch,
#       $4 cross-runner max runtime, $5 dedup helper (optional)
# Env:  STALE_REASSIGN_UPDATED_THRESHOLD_SECONDS (default 600),
#       AIDEVOPS_ORPHANED_SELF_CLAIM_CAP (default 5)
# Returns: 0 when the search saw every stale claim (processing may be capped);
#          1 when search failed, was incomplete or hit the page limit, so the
#          caller must keep the per-repo pass this run
#######################################
_normalize_unassign_stale_search() {
	local runner_user="$1"
	local repos_json="$2"
	local now_epoch="$3"
	local cross_runner_max_runtime="$4"
	local dedup_helper="${5:-}"
	local threshold="${STALE_REASSIGN_UPDATED_THRESHOLD_SECONDS:-600}"
	local cap="${AIDEVOPS_STALE_SEARCH_MAX_CANDIDATES:-20}"
	local orphan_cap="${AIDEVOPS_ORPHANED_SELF_CLAIM_CAP:-5}"
	local per_page=100
	[[ "$threshold" =~ ^[0-9]+$ ]] || threshold=600
	[[ "$cap" =~ ^[1-9][0-9]*$ ]] || cap=20
	[[ "$orphan_cap" =~ ^[0-9]+$ ]] || orphan_cap=5
	_NORMALIZE_ORPHAN_CHECKED=0
	_NORMALIZE_ORPHAN_RECOVERED=0

	local unavailable="[pulse-wrapper] Stale assignment scan (search) unavailable"
	if [[ ! "$runner_user" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ || ! -f "$repos_json" ]]; then
		echo "${unavailable}: reason=bad_input — per-repo pass kept" >>"$LOGFILE"
		return 1
	fi
	local cutoff=$((now_epoch - threshold)) cutoff_iso=""
	cutoff_iso=$(_normalize_stale_epoch_iso "$cutoff") || cutoff_iso=""
	if [[ -z "$cutoff_iso" ]]; then
		echo "${unavailable}: reason=bad_cutoff — per-repo pass kept" >>"$LOGFILE"
		return 1
	fi

	local query="is:issue is:open assignee:${runner_user} label:\"status:in-progress\",\"status:queued\" updated:<${cutoff_iso}"
	local result="" meta="" total=0 items=0 complete="false"
	if ! result=$(gh api -X GET search/issues -f q="$query" -f sort=updated -f order=asc \
		-f per_page="$per_page" 2>/dev/null); then
		echo "${unavailable}: reason=search_failed — per-repo pass kept" >>"$LOGFILE"
		return 1
	fi
	# Only an explicit incomplete_results=false is complete (jq `//` would
	# replace false, so compare instead).
	meta=$(printf '%s' "$result" | jq -r '"\(.total_count // -1) \(.items // [] | length) \(.incomplete_results == false)"' 2>/dev/null) || meta=""
	read -r total items complete <<<"$meta"
	if [[ ! "$total" =~ ^[0-9]+$ || ! "$items" =~ ^[0-9]+$ || "$complete" != "true" ]]; then
		echo "${unavailable}: reason=incomplete total=${total:-?} items=${items:-?} — per-repo pass kept" >>"$LOGFILE"
		return 1
	fi

	local rows="" row="" slug="" stale_num="" coverage_rc=0
	local candidates=0 live_local=0 rechecked_out=0 reset=0 deferred=0
	if [[ "$items" -ge "$per_page" || "$total" -gt "$items" ]]; then
		coverage_rc=1
	fi
	rows=$(_normalize_stale_search_rows "$result" "$repos_json" "$runner_user" "$cutoff") || rows=""
	local allowed_slugs=" " denied_slugs=" "
	while IFS='|' read -r slug stale_num; do
		[[ -n "$slug" && "$stale_num" =~ ^[0-9]+$ ]] || continue
		if [[ "$denied_slugs" == *" ${slug} "* ]]; then
			continue
		elif [[ "$allowed_slugs" != *" ${slug} "* ]]; then
			if ! declare -F repo_allows_pulse_write_actions >/dev/null 2>&1 ||
				! repo_allows_pulse_write_actions "$slug"; then
				denied_slugs="${denied_slugs}${slug} "
				continue
			fi
			allowed_slugs="${allowed_slugs}${slug} "
		fi
		if _normalize_stale_session_leader_live "$stale_num"; then
			live_local=$((live_local + 1))
			continue
		fi
		if [[ "$candidates" -ge "$cap" ]]; then
			deferred=$((deferred + 1))
			continue
		fi
		candidates=$((candidates + 1))
		if ! _normalize_stale_search_live_recheck "$stale_num" "$slug" "$runner_user" "$cutoff"; then
			rechecked_out=$((rechecked_out + 1))
			continue
		fi
		if _normalize_stale_process_candidate "$stale_num" "$slug" "$now_epoch" \
			"$cross_runner_max_runtime" "$runner_user" "$dedup_helper" "$orphan_cap" "$threshold"; then
			reset=$((reset + 1))
		fi
	done <<<"$rows"

	local coverage="complete"
	[[ "$coverage_rc" -eq 0 ]] || coverage="partial"
	echo "[pulse-wrapper] Stale assignment scan (search): threshold=${threshold}s results=${items} total=${total} candidates=${candidates} live_local=${live_local} recheck_dropped=${rechecked_out} reset=${reset} deferred=${deferred} orphan_checked=${_NORMALIZE_ORPHAN_CHECKED} orphan_recovered=${_NORMALIZE_ORPHAN_RECOVERED} coverage=${coverage}" >>"$LOGFILE"
	return "$coverage_rc"
}

# Substage timing when the normalization driver provides it.
_normalize_stale_log_timing() {
	local stage="$1"
	local start="$2"
	declare -F _normalize_log_timing >/dev/null 2>&1 || return 0
	_normalize_log_timing "$stage" "$start" 0
	return 0
}

#######################################
# GH#40231: claim recovery run first on every normalize run: the search
# sweep, then the pending checkpoint-lease and deferred claim-release drains
# (GH#36553, GH#37344), which used to wait for the per-repo pass's turn.
# Args: as _normalize_unassign_stale_search
# Returns: 0 when the search covered every stale claim, 1 when the caller
#          must keep the per-repo pass this run
#######################################
_normalize_claim_recovery_every_run() {
	local runner_user="$1"
	local repos_json="$2"
	local now_epoch="$3"
	local cross_runner_max_runtime="$4"
	local dedup_helper="${5:-}"
	local start=$SECONDS coverage_rc=0
	_normalize_unassign_stale_search "$runner_user" "$repos_json" "$now_epoch" \
		"$cross_runner_max_runtime" "$dedup_helper" || coverage_rc=1
	_normalize_stale_log_timing "substage:normalize/unassign_stale_search" "$start"
	start=$SECONDS
	_normalize_stale_close_pending_checkpoint_leases || true
	_normalize_deferred_claim_releases || true
	_normalize_stale_log_timing "substage:normalize/claim_release_drains" "$start"
	return "$coverage_rc"
}

# GH#40231: with complete search coverage, the per-repo stale pass is only a
# backstop for repos search cannot see. It is due when it has not started for
# AIDEVOPS_STALE_PER_REPO_BACKSTOP_S (default 6h) or its stamp is unreadable.
# Args: $1 pass state dir, $2 now epoch
# Returns: 0 due, 1 not due
_normalize_stale_per_repo_backstop_due() {
	local state_dir="$1"
	local now_epoch="$2"
	local backstop="${AIDEVOPS_STALE_PER_REPO_BACKSTOP_S:-21600}"
	[[ "$backstop" =~ ^[0-9]+$ ]] || backstop=21600
	declare -F _normalize_pass_started_within >/dev/null 2>&1 || return 0
	_normalize_pass_started_within "$state_dir" unassign_stale "$now_epoch" "$backstop" && return 1
	return 0
}

#######################################
# Pass 2c (GH#39327): release stale assignees from open status:available +
# auto-dispatch issues. _normalize_unassign_stale only sees active-status
# issues and _action_rsd_single only heals status:done, so a reopened issue
# kept a closed lifecycle's assignee, which demotes it behind all fresh work
# on every other runner (GH#38333 ordering).
#
# Fast path: _pir_prior_lifecycle_assignees names assignees added before the
# latest reopen; exactly those logins are removed. Otherwise the existing
# `dispatch-dedup-helper.sh is-assigned` guard decides: its stale recovery is
# positive-proof, fail-closed and writes the audit comment. No staleness rule
# is reimplemented here. Any read failure makes no mutation.
#
# Args:
#   $1 runner_user  — GH login of the current runner
#   $2 repos_json   — path to repos.json
#   $3 now_epoch    — current Unix timestamp
#   $4 dedup_helper — path to dispatch-dedup-helper.sh
# Env: AIDEVOPS_AVAILABLE_STALE_ASSIGNEE_CAP (default 5) issues per cycle,
#      STALE_REASSIGN_UPDATED_THRESHOLD_SECONDS (default 600)
# Returns: 0 always (best-effort)
#######################################
_normalize_unassign_available_stale() {
	local runner_user="$1"
	local repos_json="$2"
	local now_epoch="$3"
	local dedup_helper="$4"

	local cap="${AIDEVOPS_AVAILABLE_STALE_ASSIGNEE_CAP:-5}"
	[[ "$cap" =~ ^[0-9]+$ ]] || cap=5
	local threshold="${STALE_REASSIGN_UPDATED_THRESHOLD_SECONDS:-600}"
	[[ "$threshold" =~ ^[0-9]+$ ]] || threshold=600
	[[ "$now_epoch" =~ ^[0-9]+$ ]] || return 0

	local processed=0 released=0 slugs=""
	slugs=$(jq -r '.initialized_repos[] | select((.local_only // false) == false and .slug != "") | .slug // ""' "$repos_json" 2>/dev/null) || slugs=""
	if declare -F _normalize_rotated_slugs >/dev/null 2>&1; then
		slugs=$(_normalize_rotated_slugs unassign_available_stale "$slugs")
	fi

	local slug
	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue
		[[ "$processed" -lt "$cap" ]] || break
		if declare -F _normalize_mark_repo_started >/dev/null 2>&1; then
			_normalize_mark_repo_started unassign_available_stale "$slug"
		fi
		if ! declare -F repo_allows_pulse_write_actions >/dev/null 2>&1 \
			|| ! repo_allows_pulse_write_actions "$slug"; then
			continue
		fi

		local listing="" listing_rc=0
		listing=$(_normalize_repo_listing "$slug") || listing_rc=$?
		if [[ "$listing_rc" -eq 2 ]]; then
			listing=$(gh_issue_list --repo "$slug" --state open \
				--json number,assignees,labels,createdAt,updatedAt \
				--limit "$PULSE_QUEUED_SCAN_LIMIT" 2>/dev/null) || listing=""
		elif [[ "$listing_rc" -ne 0 ]]; then
			listing=""
		fi
		[[ -n "$listing" && "$listing" != "null" ]] || continue

		local candidates=""
		local frac_re='\.[0-9]+Z$'
		candidates=$(printf '%s' "$listing" | jq -r --arg cutoff "$((now_epoch - threshold))" --arg frac "$frac_re" '
			[.[] | select(
				(.labels | map(.name)) as $l
				| ($l | index("status:available")) and ($l | index("auto-dispatch"))
				and ((.assignees // []) | length > 0)
				and ([$l[] | select(. == "status:queued" or . == "status:in-progress"
					or . == "status:in-review" or . == "status:claimed"
					or . == "hold-for-review" or . == "needs-maintainer-review"
					or . == "parent-task" or . == "persistent" or . == "no-auto-dispatch")] | length == 0)
				and ((.updatedAt | sub($frac; "Z") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) < ($cutoff | tonumber))
			) | .number] | .[]' 2>/dev/null) || candidates=""
		[[ -n "$candidates" ]] || continue

		local num
		while IFS= read -r num; do
			[[ "$num" =~ ^[0-9]+$ ]] || continue
			[[ "$processed" -lt "$cap" ]] || break
			processed=$((processed + 1))

			local issue_json="" stale=""
			issue_json=$(printf '%s' "$listing" | jq -c --argjson n "$num" '.[] | select(.number == $n)' 2>/dev/null) || issue_json=""
			[[ -n "$issue_json" ]] || continue
			stale=$(_pir_prior_lifecycle_assignees "$slug" "$num" "$issue_json") || stale=""
			if [[ -n "$stale" ]]; then
				if gh issue edit "$num" --repo "$slug" --remove-assignee "$stale" >/dev/null 2>&1; then
					released=$((released + 1))
					echo "[pulse-wrapper] Available stale assignment: released prior-lifecycle assignees (${stale}) on #${num} in ${slug}" >>"$LOGFILE"
				fi
				continue
			fi
			if [[ -x "$dedup_helper" ]]; then
				# Stale recovery (and its audit comment) lives inside is-assigned.
				"$dedup_helper" is-assigned "$num" "$slug" "$runner_user" >/dev/null 2>&1 || true
			fi
		done <<<"$candidates"
	done <<<"$slugs"

	echo "[pulse-wrapper] Available stale assignment scan: cap=${cap} processed=${processed} prior_lifecycle_released=${released}" >>"$LOGFILE"
	return 0
}
