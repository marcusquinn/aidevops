#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-nmr-approval.sh — Needs-maintainer-review (NMR) cache, approval requirement checks, and maintainer auto-approve.
#
# Extracted from pulse-wrapper.sh in Phase 2 of the phased decomposition
# (parent: GH#18356, plan: todo/plans/pulse-wrapper-decomposition.md §6).
#
# This module is sourced by pulse-wrapper.sh. It MUST NOT be executed
# directly — it relies on the orchestrator having sourced:
#   shared-constants.sh
#   worker-lifecycle-common.sh
# and having defined all PULSE_* / FAST_FAIL_* / etc. configuration
# constants in the bootstrap section.
#
# Functions in this module (in source order):
#   - _ever_nmr_cache_key
#   - _ever_nmr_cache_load
#   - _ever_nmr_cache_with_lock
#   - _ever_nmr_cache_get
#   - _ever_nmr_cache_set_locked
#   - _ever_nmr_cache_set
#   - issue_was_ever_nmr
#   - issue_has_required_approval
#   - _nmr_applied_by_maintainer
#   - auto_approve_maintainer_issues
#
# This is a pure move from pulse-wrapper.sh. The function bodies are
# byte-identical to their pre-extraction form. Any change must go in a
# separate follow-up PR after the full decomposition (Phase 12) lands.

# Include guard — prevent double-sourcing.
[[ -n "${_PULSE_NMR_APPROVAL_LOADED:-}" ]] && return 0
_PULSE_NMR_APPROVAL_LOADED=1

#######################################
# Cached ever-NMR provenance helpers (GH#17458)
#
# Positive results are immutable and can be cached indefinitely.
# Negative results are cached for a short TTL to avoid a timeline API call
# on every dispatch candidate while still noticing new NMR labels promptly.
#######################################
_ever_nmr_cache_key() {
	local issue_num="$1"
	local slug="$2"
	printf '%s\n' "${slug}#${issue_num}"
	return 0
}

_ever_nmr_cache_load() {
	if [[ ! -f "$EVER_NMR_CACHE_FILE" ]]; then
		printf '{}\n'
		return 0
	fi

	local content
	content=$(cat "$EVER_NMR_CACHE_FILE" 2>/dev/null) || content="{}"
	if ! printf '%s' "$content" | jq empty >/dev/null 2>&1; then
		content="{}"
	fi

	printf '%s\n' "$content"
	return 0
}

_ever_nmr_cache_with_lock() {
	local lock_dir="${EVER_NMR_CACHE_FILE}.lockdir"
	local retries=0
	while ! mkdir "$lock_dir" 2>/dev/null; do
		retries=$((retries + 1))
		if [[ "$retries" -ge 50 ]]; then
			echo "[pulse-wrapper] _ever_nmr_cache_with_lock: lock acquisition timed out" >>"$LOGFILE"
			return 1
		fi
		# Stale lock detection: read the owner PID stored in the lock directory.
		# If that process is no longer running, the lock is orphaned — clear it.
		local _nmr_owner_pid
		_nmr_owner_pid=$(cat "${lock_dir}/owner.pid" 2>/dev/null || true)
		if [[ -n "$_nmr_owner_pid" ]] && ! kill -0 "$_nmr_owner_pid" 2>/dev/null; then
			echo "[pulse-wrapper] _ever_nmr_cache_with_lock: clearing stale lock (owner PID ${_nmr_owner_pid} gone)" >>"$LOGFILE"
			rm -f "${lock_dir}/owner.pid" 2>/dev/null || true
			rmdir "$lock_dir" 2>/dev/null || true
			continue
		fi
		sleep 0.1
	done

	# Record owner PID inside lock directory so retrying callers can detect staleness.
	printf '%s\n' "$$" >"${lock_dir}/owner.pid" 2>/dev/null || true
	local rc=0
	"$@" || rc=$?
	rm -f "${lock_dir}/owner.pid" 2>/dev/null || true
	rmdir "$lock_dir" 2>/dev/null || true
	return "$rc"
}

_ever_nmr_cache_get() {
	local issue_num="$1"
	local slug="$2"
	local key now_epoch cache_json cache_value checked_at age

	key=$(_ever_nmr_cache_key "$issue_num" "$slug")
	now_epoch=$(date +%s)
	cache_json=$(_ever_nmr_cache_load)
	cache_value=$(printf '%s' "$cache_json" | jq -r --arg key "$key" 'if .[$key] == null then "unknown" elif .[$key].ever_nmr == true then "true" elif .[$key].ever_nmr == false then "false" else "unknown" end' 2>/dev/null) || cache_value="unknown"
	checked_at=$(printf '%s' "$cache_json" | jq -r --arg key "$key" '.[$key].checked_at // 0' 2>/dev/null) || checked_at=0
	[[ "$checked_at" =~ ^[0-9]+$ ]] || checked_at=0

	if [[ "$cache_value" == "true" ]]; then
		printf 'true\n'
		return 0
	fi

	if [[ "$cache_value" == "false" ]]; then
		age=$((now_epoch - checked_at))
		if [[ "$age" -lt "$EVER_NMR_NEGATIVE_CACHE_TTL_SECS" ]]; then
			printf 'false\n'
			return 0
		fi
	fi

	printf 'unknown\n'
	return 0
}

_ever_nmr_cache_set_locked() {
	local issue_num="$1"
	local slug="$2"
	local cache_value="$3"
	local state_dir cache_json key now_epoch tmp_file

	[[ "$cache_value" == "true" || "$cache_value" == "false" ]] || return 1

	state_dir=$(dirname "$EVER_NMR_CACHE_FILE")
	mkdir -p "$state_dir" 2>/dev/null || true
	cache_json=$(_ever_nmr_cache_load)
	key=$(_ever_nmr_cache_key "$issue_num" "$slug")
	now_epoch=$(date +%s)
	tmp_file=$(mktemp "${state_dir}/.ever-nmr-cache.XXXXXX" 2>/dev/null) || return 0

	if printf '%s' "$cache_json" | jq --arg key "$key" --argjson checked_at "$now_epoch" --argjson ever_nmr "$cache_value" '.[$key] = {ever_nmr: $ever_nmr, checked_at: $checked_at}' >"$tmp_file" 2>/dev/null; then
		mv "$tmp_file" "$EVER_NMR_CACHE_FILE" || {
			rm -f "$tmp_file"
			echo "[pulse-wrapper] _ever_nmr_cache_set_locked: failed to move cache file" >>"$LOGFILE"
		}
	else
		rm -f "$tmp_file"
		echo "[pulse-wrapper] _ever_nmr_cache_set_locked: failed to write cache entry" >>"$LOGFILE"
	fi

	return 0
}

_ever_nmr_cache_set() {
	_ever_nmr_cache_with_lock _ever_nmr_cache_set_locked "$@" || return 0
	return 0
}

#######################################
# Check if an issue was ever labeled needs-maintainer-review (t1894).
# Uses the immutable GitHub timeline API — label removal does not erase
# the history. This is the provenance gate: once an issue is tagged NMR,
# it requires cryptographic approval forever, regardless of current labels.
#
# Arguments:
#   $1 - issue number
#   $2 - repo slug (owner/repo)
#   $3 - optional precomputed status: true|false|unknown
# Returns: 0 if the issue was ever NMR-labeled, 1 otherwise
#######################################
issue_was_ever_nmr() {
	local issue_num="$1"
	local slug="$2"
	local known_status="${3:-unknown}"

	[[ -n "$issue_num" && -n "$slug" ]] || return 1

	case "$known_status" in
	true)
		return 0
		;;
	false)
		return 1
		;;
	esac

	local cache_status
	cache_status=$(_ever_nmr_cache_get "$issue_num" "$slug")
	case "$cache_status" in
	true)
		return 0
		;;
	false)
		return 1
		;;
	esac

	local ever_count
	ever_count=$(gh api "repos/${slug}/issues/${issue_num}/timeline" --paginate \
		--jq '[.[] | select(.event == "labeled" and .label.name == "needs-maintainer-review")] | length' \
		2>/dev/null) || ever_count=0
	[[ "$ever_count" =~ ^[0-9]+$ ]] || ever_count=0

	if [[ "$ever_count" -gt 0 ]]; then
		_ever_nmr_cache_set "$issue_num" "$slug" "true"
		return 0
	fi

	_ever_nmr_cache_set "$issue_num" "$slug" "false"
	return 1
}

#######################################
# Check if an issue requires cryptographic approval and has it (t1894).
# Combines the "ever-NMR" provenance check with signature verification.
#
# Arguments:
#   $1 - issue number
#   $2 - repo slug (owner/repo)
#   $3 - optional precomputed status: true|false|unknown
# Returns: 0 if the issue is approved (or never needed approval), 1 if blocked
#######################################
issue_has_required_approval() {
	local issue_num="$1"
	local slug="$2"
	local known_status="${3:-unknown}"

	# If it was never NMR-labeled, no approval needed
	if ! issue_was_ever_nmr "$issue_num" "$slug" "$known_status"; then
		return 0
	fi

	# It was NMR-labeled at some point — check for cryptographic approval
	local approval_helper="${AGENTS_DIR:-$HOME/.aidevops/agents}/scripts/approval-helper.sh"
	if [[ -f "$approval_helper" ]]; then
		local verify_result
		verify_result=$(bash "$approval_helper" verify "$issue_num" "$slug" 2>/dev/null) || verify_result=""
		if [[ "$verify_result" == "VERIFIED" ]]; then
			return 0
		fi
	fi

	# Was ever NMR, no signed approval found — blocked
	return 1
}

#######################################
# GH#18671 (Fix 6b): Check whether an NMR label application on an issue
# was accompanied by a pulse automation signature — a comment posted
# immediately after (or within a ~60-second window of) the label event
# that identifies the automated escalation path.
#
# Without this check, `_nmr_applied_by_maintainer` treats every NMR
# application by the maintainer's GitHub token as a manual hold, even
# when it was the t2008 stale-recovery circuit breaker, the t2007 cost
# circuit breaker, or the GH#18538 review-scanner default-NMR path.
# That is the direct cause of the "NMR drain" where workers crash in
# ~17s during setup (pre-creation bug, Fix 6a), get stale-recovered,
# hit the threshold, and are escalated to NMR. The maintainer never
# touched the label, but auto_approve skips them because
# _nmr_applied_by_maintainer returns true, and the issues stay blocked
# until the human manually runs `sudo aidevops approve issue NNN`.
#
# Automation signatures detected (all are idempotent markers the pulse
# leaves when it applies NMR via an escalation path):
#   - <!-- stale-recovery-tick:escalated   — t2008 stale recovery
#   - <!-- cost-circuit-breaker:fired      — t2007 cost circuit breaker
#   - <!-- circuit-breaker-escalated       — legacy fast-fail alias
#   - <!-- source:review-scanner           — GH#18538 scanner default NMR
#
# Args:
#   $1 - issue_num  : GitHub issue number
#   $2 - slug       : repo slug (owner/repo)
#   $3 - label_at   : ISO8601 timestamp when NMR label was applied
#
# Exit codes:
#   0 - automation signature found (NMR was auto-applied, safe to clear)
#   1 - no automation signature (NMR was likely a manual hold)
#######################################
_nmr_application_has_automation_signature() {
	local issue_num="$1"
	local slug="$2"
	local label_at="$3"

	[[ -n "$issue_num" && -n "$slug" && -n "$label_at" ]] || return 1

	# Fetch all issue comments once. Filter in jq to any comment posted
	# within a 60-second window of the label event AND containing a known
	# automation marker. The 60s window is generous for API latency between
	# the label API call and the follow-up comment post, while still tight
	# enough to exclude unrelated maintainer activity.
	#
	# Window math: label_at - 5s ≤ comment.created_at ≤ label_at + 60s.
	# Lower bound covers the case where the comment was posted first and
	# the label application was slightly delayed (rare but observed).
	local has_signature
	has_signature=$(gh api "repos/${slug}/issues/${issue_num}/comments" --paginate \
		--jq "[.[] | select((.created_at | fromdateiso8601) >= ((\"${label_at}\" | fromdateiso8601) - 5) and (.created_at | fromdateiso8601) <= ((\"${label_at}\" | fromdateiso8601) + 60)) | .body | select(test(\"stale-recovery-tick:escalated|cost-circuit-breaker:fired|circuit-breaker-escalated|source:review-scanner\"))] | length" \
		2>/dev/null) || has_signature=0
	[[ "$has_signature" =~ ^[0-9]+$ ]] || has_signature=0

	if [[ "$has_signature" -gt 0 ]]; then
		return 0
	fi

	# Also accept: the issue itself carries review-followup or
	# source:review-scanner labels (bot-generated cleanup from
	# post-merge-review-scanner.sh, GH#18538). These issues apply NMR at
	# creation via the scanner's SCANNER_NEEDS_REVIEW=true default, which
	# does not necessarily emit a post-label comment marker. The label
	# presence itself is the automation signature.
	local has_bot_label
	has_bot_label=$(gh api "repos/${slug}/issues/${issue_num}" \
		--jq '[.labels[].name] | map(select(. == "review-followup" or . == "source:review-scanner")) | length' \
		2>/dev/null) || has_bot_label=0
	[[ "$has_bot_label" =~ ^[0-9]+$ ]] || has_bot_label=0

	if [[ "$has_bot_label" -gt 0 ]]; then
		return 0
	fi

	return 1
}

#######################################
# Check if the needs-maintainer-review label was most recently applied
# by the maintainer themselves (indicating a manual hold).
#
# GH#18671 (Fix 6b): the pulse runs as the maintainer's GitHub token, so
# `actor.login == maintainer` matches both human manual label actions
# AND automated escalation paths (t2007 cost circuit breaker, t2008
# stale-recovery, GH#18538 scanner default-NMR). This function now
# consults `_nmr_application_has_automation_signature` — if the label
# event has an adjacent automation marker comment (or the issue itself
# carries bot-cleanup labels), it classifies as automation-applied and
# returns 1 so `auto_approve_maintainer_issues` can clear the label.
#
# Arguments:
#   $1 - issue_num  : GitHub issue number
#   $2 - slug       : repo slug (owner/repo)
#   $3 - maintainer : maintainer GitHub login
#
# Returns 0 if the maintainer applied NMR AND no automation signature
#           is present (genuine manual hold — do NOT auto-approve).
# Returns 1 if NMR was applied by automation, the actor is unknown, or
#           the label event is paired with an automation marker.
#######################################
_nmr_applied_by_maintainer() {
	local issue_num="$1"
	local slug="$2"
	local maintainer="$3"

	[[ -n "$issue_num" && -n "$slug" && -n "$maintainer" ]] || return 1

	# Fetch both actor and creation timestamp of the latest NMR label event.
	local nmr_event_json
	nmr_event_json=$(gh api "repos/${slug}/issues/${issue_num}/timeline" --paginate \
		--jq '[.[] | select(.event == "labeled" and .label.name == "needs-maintainer-review")] | last | {actor:(.actor.login // ""),at:(.created_at // "")}' \
		2>/dev/null) || nmr_event_json=""

	local nmr_actor nmr_at
	nmr_actor=$(printf '%s' "$nmr_event_json" | jq -r '.actor // ""' 2>/dev/null) || nmr_actor=""
	nmr_at=$(printf '%s' "$nmr_event_json" | jq -r '.at // ""' 2>/dev/null) || nmr_at=""

	if [[ "$nmr_actor" != "$maintainer" ]]; then
		return 1
	fi

	# Actor matches the maintainer — but is this a real manual action or
	# the pulse running as the maintainer's token? Check for automation
	# signature adjacent to the label event.
	if [[ -n "$nmr_at" ]] && _nmr_application_has_automation_signature "$issue_num" "$slug" "$nmr_at"; then
		echo "[pulse-wrapper] _nmr_applied_by_maintainer: #${issue_num} in ${slug} — actor=${maintainer} but automation signature detected — classifying as automation-applied (GH#18671)" >>"$LOGFILE"
		return 1
	fi

	return 0
}

#######################################
# Auto-approve needs-maintainer-review issues using cryptographic
# signature verification (t1894, replaces GH#16842 comment-based check).
#
# The review gate exists for external contributions. Approval requires
# a cryptographically signed comment posted via `sudo aidevops approve
# issue <number>`. This ensures only a human with the system password
# (and root access to the approval signing key) can approve issues.
#
# Fallback: maintainer-authored issues are still auto-approved (the
# maintainer wouldn't gate their own issues), UNLESS the maintainer
# manually applied NMR themselves — that signals an intentional hold
# and must be preserved. Comment-based approval is removed — workers
# share the same GitHub account so any comment from the account is
# indistinguishable from a human comment.
#######################################
auto_approve_maintainer_issues() {
	local repos_json="$REPOS_JSON"
	[[ -f "$repos_json" ]] || return 0

	local total_approved=0
	local approval_helper="${AGENTS_DIR:-$HOME/.aidevops/agents}/scripts/approval-helper.sh"

	while IFS='|' read -r slug maintainer; do
		[[ -n "$slug" && -n "$maintainer" ]] || continue

		# Get all open needs-maintainer-review issues
		local nmr_json
		nmr_json=$(gh issue list --repo "$slug" --label "needs-maintainer-review" \
			--state open --json number,author --limit 100 2>/dev/null) || nmr_json="[]"
		[[ -n "$nmr_json" && "$nmr_json" != "null" ]] || continue

		local nmr_count
		nmr_count=$(printf '%s' "$nmr_json" | jq 'length' 2>/dev/null) || nmr_count=0
		[[ "$nmr_count" -gt 0 ]] || continue

		local i=0
		while [[ "$i" -lt "$nmr_count" ]]; do
			local issue_num issue_author
			issue_num=$(printf '%s' "$nmr_json" | jq -r ".[$i].number" 2>/dev/null)
			issue_author=$(printf '%s' "$nmr_json" | jq -r ".[$i].author.login // empty" 2>/dev/null)
			i=$((i + 1))
			[[ "$issue_num" =~ ^[0-9]+$ ]] || continue

			local should_approve=false
			local approval_reason=""

			# Case 1: maintainer created the issue — auto-approve unless NMR
			# was manually applied by the maintainer (intentional hold).
			if [[ "$issue_author" == "$maintainer" ]]; then
				if _nmr_applied_by_maintainer "$issue_num" "$slug" "$maintainer"; then
					echo "[pulse-wrapper] Skipping auto-approve for #${issue_num} in ${slug} — NMR manually applied by maintainer" >>"$LOGFILE"
				else
					should_approve=true
					approval_reason="maintainer is author, NMR applied by automation"
				fi
			fi

			# Case 2: cryptographic approval signature found
			if [[ "$should_approve" == "false" && -f "$approval_helper" ]]; then
				local verify_result
				verify_result=$(bash "$approval_helper" verify "$issue_num" "$slug" 2>/dev/null) || verify_result=""
				if [[ "$verify_result" == "VERIFIED" ]]; then
					should_approve=true
					approval_reason="cryptographic approval verified"
				fi
			fi

			if [[ "$should_approve" == "true" ]]; then
				# Post the approval marker BEFORE removing the label.
				# maintainer-gate.yml checks for <!-- aidevops-signed-approval -->
				# when NMR is removed — if the marker is missing, it re-adds NMR.
				# Without this, the pulse and the CI workflow fight: pulse removes
				# NMR, CI re-adds it (no signed approval found), infinite loop.
				# Also resets the stale-recovery tick counter.
				gh issue comment "$issue_num" --repo "$slug" \
					--body "<!-- aidevops-signed-approval -->
<!-- stale-recovery-tick:0 (reset: auto-approved by maintainer — ${approval_reason}) -->
Auto-approved: ${approval_reason}. Stale recovery tick reset." \
					2>/dev/null || true

				gh issue edit "$issue_num" --repo "$slug" \
					--remove-label "needs-maintainer-review" \
					--add-label "auto-dispatch" >/dev/null 2>&1 || true
				echo "[pulse-wrapper] Auto-approved #${issue_num} in ${slug} — ${approval_reason} (approval marker + tick reset)" >>"$LOGFILE"
				total_approved=$((total_approved + 1))
			fi
		done
	done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | "\(.slug)|\(.maintainer // (.slug | split("/")[0]))"' "$repos_json" 2>/dev/null)

	if [[ "$total_approved" -gt 0 ]]; then
		echo "[pulse-wrapper] Auto-approve maintainer issues: approved ${total_approved} issue(s)" >>"$LOGFILE"
	fi

	return 0
}
