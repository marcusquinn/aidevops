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
#   - notify_ever_nmr_without_approval
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
# GH#18671 / t2386: Check whether an NMR label application on an issue
# corresponds to a *creation-time automation default* — a marker that
# means "the pulse applied NMR by default, not because retries failed."
# Creation defaults are safe to auto-clear so the issue can dispatch.
#
# This function used to also match circuit-breaker trip markers
# (stale-recovery-tick:escalated, cost-circuit-breaker:fired,
# circuit-breaker-escalated). That was a design bug: it caused
# auto_approve_maintainer_issues to strip NMR from breaker-tripped
# issues immediately, re-dispatch the worker, let it fail again, and
# re-trip the breaker — an infinite loop. #19756 burned ~30 worker
# sessions and fired 22 watchdog kills + 5 auto-approve cycles in one
# afternoon before the loop was diagnosed.
#
# Breaker trip detection now lives in `_nmr_application_is_circuit_breaker_trip`
# below. `_nmr_applied_by_maintainer` consults both helpers and routes
# breaker trips to "preserve NMR" while still auto-clearing
# creation defaults. See t2386 brief and `prompts/build.txt`
# "Cryptographic issue/PR approval" for the split semantics.
#
# Creation-default signatures detected (t2686 extended set):
#   - source:review-scanner                 — GH#18538 post-merge-review-scanner.sh (comment marker)
#   - source:review-feedback                — quality-feedback-helper.sh (comment marker)
#   - quality-feedback-helper.sh            — quality-feedback-helper.sh (comment body marker)
#   - review-followup / source:review-scanner / source:review-feedback labels on issue itself
#
# Args:
#   $1 - issue_num  : GitHub issue number
#   $2 - slug       : repo slug (owner/repo)
#   $3 - label_at   : ISO8601 timestamp when NMR label was applied
#
# Exit codes:
#   0 - creation-default signature found (NMR is a scanner default, safe to auto-clear)
#   1 - no creation-default signature (NMR is either manual or a breaker trip)
#######################################
_nmr_application_has_automation_signature() {
	local issue_num="$1"
	local slug="$2"
	local label_at="$3"

	[[ -n "$issue_num" && -n "$slug" && -n "$label_at" ]] || return 1

	# Fetch all issue comments once. Filter in jq to any comment posted
	# within a 60-second window of the label event AND containing a
	# creation-default marker. Window math: label_at - 5s ≤
	# comment.created_at ≤ label_at + 60s (lower bound covers the API
	# latency race where the comment posts before the label API call
	# completes).
	#
	# Markers matched (t2686 extended set):
	#   - source:review-scanner     — post-merge-review-scanner.sh (GH#18538)
	#   - source:review-feedback    — quality-feedback-helper.sh scan-merged
	#   - quality-feedback-helper.sh — approval-instructions comment body
	local has_signature
	has_signature=$(gh api "repos/${slug}/issues/${issue_num}/comments" --paginate \
		--jq "[.[] | select((.created_at | fromdateiso8601) >= ((\"${label_at}\" | fromdateiso8601) - 5) and (.created_at | fromdateiso8601) <= ((\"${label_at}\" | fromdateiso8601) + 60)) | .body | select(test(\"source:review-scanner|source:review-feedback|quality-feedback-helper\\\\.sh\"))] | length" \
		2>/dev/null) || has_signature=0
	[[ "$has_signature" =~ ^[0-9]+$ ]] || has_signature=0

	if [[ "$has_signature" -gt 0 ]]; then
		return 0
	fi

	# Also accept: the issue itself carries a scanner provenance label
	# (bot-generated cleanup). These issues apply NMR at creation via the
	# scanner default, which does not necessarily emit a post-label comment
	# marker.
	#
	# GH#20758: Co-temporality guard — scanner labels persist for the life
	# of the issue, so a label-only match without timing verification
	# misclassifies later NMR events (manual holds, breaker trips) as
	# creation defaults. Only match when NMR was applied within 300s of
	# issue creation. This closes the ever-NMR trap for scanner-labelled
	# issues that subsequently trip a circuit breaker.
	#
	# Labels matched (t2686 extended set):
	#   - review-followup           — post-merge-review-scanner.sh (GH#18538)
	#   - source:review-scanner     — post-merge-review-scanner.sh
	#   - source:review-feedback    — quality-feedback-helper.sh scan-merged
	local issue_meta_json
	issue_meta_json=$(gh api "repos/${slug}/issues/${issue_num}" 2>/dev/null) || issue_meta_json=""

	local has_bot_label=0
	if [[ -n "$issue_meta_json" ]]; then
		has_bot_label=$(printf '%s' "$issue_meta_json" \
			| jq '[.labels[].name] | map(select(. == "review-followup" or . == "source:review-scanner" or . == "source:review-feedback")) | length' \
			2>/dev/null) || has_bot_label=0
	fi
	[[ "$has_bot_label" =~ ^[0-9]+$ ]] || has_bot_label=0

	if [[ "$has_bot_label" -gt 0 ]]; then
		# Co-temporality check: NMR must have been applied within 300s of
		# issue creation to classify as a creation default. Later NMR events
		# on the same issue are either manual holds or breaker trips.
		local issue_created_at
		issue_created_at=$(printf '%s' "$issue_meta_json" \
			| jq -r '.created_at // ""' 2>/dev/null) || issue_created_at=""
		if [[ -n "$issue_created_at" && -n "$label_at" ]]; then
			local nmr_creation_gap
		nmr_creation_gap=$(jq -n --arg c "$issue_created_at" --arg l "$label_at" \
			'(($l | fromdateiso8601) - ($c | fromdateiso8601)) | abs | floor') || nmr_creation_gap=999999
			[[ "$nmr_creation_gap" =~ ^[0-9]+$ ]] || nmr_creation_gap=999999
			if (( nmr_creation_gap <= 300 )); then
				return 0
			fi
		fi
		# Scanner label present but NMR applied far from creation — not a
		# creation default. Fall through to return 1.
	fi

	return 1
}

#######################################
# t2386: Check whether an NMR label application corresponds to a
# circuit-breaker trip — one of the automated safety mechanisms that
# STOPS further dispatch when a retry limit has been exceeded or a
# cost budget has been exhausted.
#
# Breaker trips MUST preserve NMR. auto_approve_maintainer_issues
# skips issues with a breaker-trip signature, leaving NMR in place
# until a human runs `sudo aidevops approve issue <N>` after reviewing
# why the breaker tripped. This is the safety mechanism whose defeat
# caused the #19756 infinite-loop incident.
#
# Breaker-trip signatures detected:
#   - <!-- stale-recovery-tick:escalated   — t2008 stale recovery (retry limit)
#   - <!-- cost-circuit-breaker:fired      — t2007 cost circuit breaker (budget)
#   - <!-- cost-circuit-breaker:no_work_loop — t2769 per-issue no_work breaker
#   - <!-- circuit-breaker-escalated       — legacy fast-fail alias
#
# Args:
#   $1 - issue_num  : GitHub issue number
#   $2 - slug       : repo slug (owner/repo)
#   $3 - label_at   : ISO8601 timestamp when NMR label was applied
#
# Exit codes:
#   0 - breaker-trip signature found (NMR must be preserved)
#   1 - no breaker-trip signature
#######################################
_nmr_application_is_circuit_breaker_trip() {
	local issue_num="$1"
	local slug="$2"
	local label_at="$3"

	[[ -n "$issue_num" && -n "$slug" && -n "$label_at" ]] || return 1

	# Same ±60s window as _nmr_application_has_automation_signature —
	# breaker helpers (dispatch-dedup-stale.sh, dispatch-dedup-cost.sh,
	# and the t2769 no_work breaker in worker-lifecycle-common.sh) post
	# the marker comment immediately after applying the NMR label,
	# so the two events are always co-temporal.
	local has_breaker_trip
	has_breaker_trip=$(gh api "repos/${slug}/issues/${issue_num}/comments" --paginate \
		--jq "[.[] | select((.created_at | fromdateiso8601) >= ((\"${label_at}\" | fromdateiso8601) - 5) and (.created_at | fromdateiso8601) <= ((\"${label_at}\" | fromdateiso8601) + 60)) | .body | select(test(\"stale-recovery-tick:escalated|cost-circuit-breaker:fired|cost-circuit-breaker:no_work_loop|circuit-breaker-escalated\"))] | length" \
		2>/dev/null) || has_breaker_trip=0
	[[ "$has_breaker_trip" =~ ^[0-9]+$ ]] || has_breaker_trip=0

	if [[ "$has_breaker_trip" -gt 0 ]]; then
		return 0
	fi

	return 1
}

#######################################
# Check if the needs-maintainer-review label was most recently applied
# by the maintainer themselves (indicating a manual hold), OR by a
# circuit breaker trip (which must be treated as a hold even though
# the token actor is the maintainer).
#
# GH#18671 / t2386: the pulse runs as the maintainer's GitHub token,
# so `actor.login == maintainer` matches all three cases:
#   1. Human maintainer clicks the label (manual hold)
#   2. Pulse scanner applies default NMR at creation (auto-clear OK)
#   3. Circuit breaker trips (t2007 cost / t2008 stale) — MUST preserve
#
# Cases 1 and 3 are both "preserve NMR" (return 0); case 2 is
# "auto-clear OK" (return 1). The split is driven by the two companion
# helpers `_nmr_application_has_automation_signature` (creation
# defaults) and `_nmr_application_is_circuit_breaker_trip` (breaker
# trips). See t2386 brief for the #19756 infinite-loop incident that
# motivated the split.
#
# Arguments:
#   $1 - issue_num  : GitHub issue number
#   $2 - slug       : repo slug (owner/repo)
#   $3 - maintainer : maintainer GitHub login
#
# Returns 0 if the maintainer applied NMR AND no creation-default
#           signature is present (manual hold or breaker trip — do NOT
#           auto-approve).
# Returns 1 if NMR was applied by a scanner default or the actor is
#           unknown (auto-approve OK).
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

	# Actor matches the maintainer. Three possibilities:
	#   1. Creation-default signature (scanner applied NMR at creation
	#      time) → auto-approve OK, return 1.
	#   2. Circuit-breaker trip signature (t2007/t2008 fired) →
	#      PRESERVE NMR, return 0 with distinct log line so operators
	#      see it was a breaker trip, not a manual hold.
	#   3. No signature → genuine manual hold, return 0.
	if [[ -n "$nmr_at" ]]; then
		# GH#20758: Circuit-breaker check FIRST — a co-temporal breaker
		# marker is a stronger signal than label persistence. Scanner-
		# labelled issues that trip a breaker MUST preserve NMR regardless
		# of creation provenance. The prior order (automation-signature
		# first) let the label-based branch of _nmr_application_has_
		# automation_signature short-circuit the breaker check because
		# scanner labels persist for the issue's lifetime.
		if _nmr_application_is_circuit_breaker_trip "$issue_num" "$slug" "$nmr_at"; then
			echo "[pulse-wrapper] _nmr_applied_by_maintainer: #${issue_num} in ${slug} — circuit breaker tripped — PRESERVING NMR, requires 'sudo aidevops approve issue ${issue_num}' (t2386/GH#20758)" >>"$LOGFILE"
			return 0
		fi
		if _nmr_application_has_automation_signature "$issue_num" "$slug" "$nmr_at"; then
			echo "[pulse-wrapper] _nmr_applied_by_maintainer: #${issue_num} in ${slug} — actor=${maintainer} but creation-default signature detected — classifying as automation-applied (GH#18671)" >>"$LOGFILE"
			return 1
		fi
	fi

	return 0
}

#######################################
# Post a one-shot remediation comment when a maintainer manually removes
# the needs-maintainer-review label but the ever-NMR history flag is still
# set and no cryptographic approval exists (GH#20682).
#
# Without this, pulse silently skips dispatch with:
#   [pulse-wrapper] dispatch_with_dedup: BLOCKED #N — requires cryptographic
#   approval (ever-NMR)
# ...and the maintainer has no user-facing signal that cryptographic approval
# is still required. This function posts an explanatory comment exactly once.
#
# Detection logic (all four conditions must hold):
#   1. Label needs-maintainer-review is absent (label was removed by human)
#   2. ever-NMR history is set (issue_was_ever_nmr returns true)
#   3. No cryptographic approval comment exists (approval-helper verify != VERIFIED)
#   4. No prior <!-- ever-nmr-remediation --> marker exists (idempotency guard)
#
# Arguments:
#   $1 - issue_number  : GitHub issue number
#   $2 - repo_slug     : owner/repo
#
# Returns: 0 always (fail-open — a missed comment is better than a broken
#          dispatch loop).
#######################################
notify_ever_nmr_without_approval() {
	local issue_number="$1"
	local repo_slug="$2"

	[[ -n "$issue_number" && -n "$repo_slug" ]] || return 0

	# Condition 1: label must be absent. Callers that have already determined
	# the label is absent pass us; callers can also call us directly and we
	# verify here.
	local has_nmr_label
	has_nmr_label=$(gh api "repos/${repo_slug}/issues/${issue_number}" \
		--jq '.labels | map(.name) | index("needs-maintainer-review") != null' \
		2>/dev/null) || has_nmr_label="false"
	if [[ "$has_nmr_label" == "true" ]]; then
		# Label still present — no remediation needed, block is visible to user.
		return 0
	fi

	# Condition 2: issue must have ever-NMR history (timeline check via cache).
	if ! issue_was_ever_nmr "$issue_number" "$repo_slug"; then
		return 0
	fi

	# Condition 3: no cryptographic approval exists.
	# Delegate to issue_has_required_approval with known_status="true" (ever-NMR
	# confirmed above) so that only the approval helper is consulted, short-
	# circuiting the redundant timeline API call for ever-NMR provenance.
	if issue_has_required_approval "$issue_number" "$repo_slug" "true"; then
		# Approved — block will clear on next dispatch cycle.
		return 0
	fi

	# Condition 4: idempotency guard — never post twice.
	local already_notified
	already_notified=$(gh api "repos/${repo_slug}/issues/${issue_number}/comments" --paginate \
		--jq '[.[] | select(.body | test("ever-nmr-remediation"))] | length' \
		2>/dev/null) || already_notified=0
	[[ "$already_notified" =~ ^[0-9]+$ ]] || already_notified=0
	if [[ "$already_notified" -gt 0 ]]; then
		echo "[pulse-wrapper] notify_ever_nmr_without_approval: #${issue_number} in ${repo_slug} — remediation comment already posted, skipping" >>"$LOGFILE"
		return 0
	fi

	# All four conditions met — post the remediation comment.
	echo "[pulse-wrapper] notify_ever_nmr_without_approval: #${issue_number} in ${repo_slug} — posting ever-NMR remediation comment (GH#20682)" >>"$LOGFILE"

	gh_issue_comment "$issue_number" --repo "$repo_slug" \
		--body "<!-- ever-nmr-remediation -->
> Label \`needs-maintainer-review\` was removed, but the \`ever-NMR\` history flag is still set. Pulse will continue to skip dispatch until cryptographic approval lands:
>
> \`\`\`
> sudo aidevops approve issue ${issue_number}
> \`\`\`
>
> This gate cannot be bypassed by label manipulation (security design — see \`reference/auto-merge.md\` NMR section)." \
		2>/dev/null || {
		echo "[pulse-wrapper] notify_ever_nmr_without_approval: #${issue_number} in ${repo_slug} — failed to post remediation comment" >>"$LOGFILE"
	}

	return 0
}

#######################################
# t2845: Handle knowledge-review issue promotion after cryptographic approval.
#
# When auto_approve_maintainer_issues clears NMR on a kind:knowledge-review
# issue, this function extracts the source_id from the body marker
# (<!-- aidevops:knowledge-review source_id:xxx -->), calls
# knowledge-review-helper.sh promote <source_id> to move staging -> sources,
# posts a closing comment, and closes the issue.
#
# Arguments:
#   $1 - issue_num  : GitHub issue number
#   $2 - slug       : repo slug (owner/repo)
#
# Returns: 0 always (fail-open — a missed promotion is better than a broken
#          approval loop).
#######################################
_handle_knowledge_review_promotion() {
	local issue_num="$1"
	local slug="$2"

	[[ -n "$issue_num" && -n "$slug" ]] || return 0

	# Shared API path (avoids repeated literal, which would trip the string-literal ratchet)
	local issue_api="repos/${slug}/issues/${issue_num}"

	# Only act on kind:knowledge-review issues
	local has_kr_label
	has_kr_label=$(gh api "$issue_api" \
		--jq '.labels | map(.name) | map(select(. == "kind:knowledge-review")) | length' \
		2>/dev/null) || has_kr_label=0
	[[ "$has_kr_label" =~ ^[0-9]+$ ]] || has_kr_label=0
	[[ "$has_kr_label" -gt 0 ]] || return 0

	# Extract source_id from body marker <!-- aidevops:knowledge-review source_id:xxx -->
	local issue_body
	issue_body=$(gh api "$issue_api" \
		--jq '.body // ""' 2>/dev/null) || issue_body=""

	local source_id
	source_id=$(printf '%s' "$issue_body" \
		| grep -oE 'source_id:[a-zA-Z0-9_.-]+' \
		| head -1 \
		| cut -d: -f2 2>/dev/null) || source_id=""

	if [[ -z "$source_id" ]]; then
		echo "[pulse-wrapper] _handle_knowledge_review_promotion: #${issue_num} in ${slug} — no source_id in body, skipping" >>"$LOGFILE"
		return 0
	fi

	# Locate knowledge-review-helper.sh in the deployed agents dir
	local kr_helper="${AGENTS_DIR:-$HOME/.aidevops/agents}/scripts/knowledge-review-helper.sh"
	if [[ ! -f "$kr_helper" ]]; then
		echo "[pulse-wrapper] _handle_knowledge_review_promotion: helper not found at ${kr_helper}" >>"$LOGFILE"
		return 0
	fi

	# Promote source from staging -> sources
	if ! bash "$kr_helper" promote "$source_id" 2>/dev/null; then
		echo "[pulse-wrapper] _handle_knowledge_review_promotion: #${issue_num} — promote '${source_id}' failed, issue stays open" >>"$LOGFILE"
		return 0
	fi

	echo "[pulse-wrapper] _handle_knowledge_review_promotion: #${issue_num} in ${slug} — promoted '${source_id}' to sources/" >>"$LOGFILE"

	# Post closing comment then close the issue
	gh_issue_comment "$issue_num" --repo "$slug" \
		--body "<!-- aidevops:knowledge-review-complete -->
Knowledge source \`${source_id}\` promoted from staging to \`sources/\` after cryptographic approval. Audit log updated." \
		2>/dev/null || true

	gh issue close "$issue_num" --repo "$slug" 2>/dev/null || true
	echo "[pulse-wrapper] _handle_knowledge_review_promotion: #${issue_num} in ${slug} — closed" >>"$LOGFILE"
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
		nmr_json=$(gh_issue_list --repo "$slug" --label "needs-maintainer-review" \
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
				# Lock the issue BEFORE posting the approval marker to prevent
				# comment prompt-injection. The marker (<!-- aidevops-signed-approval -->)
				# is trusted by maintainer-gate.yml — if an attacker could post a
				# comment containing it, they could bypass the NMR gate. Locking
				# ensures only collaborators can comment during the approval window.
				# The issue stays locked through dispatch (t1934) and unlocks after
				# the worker completes.
				gh issue lock "$issue_num" --repo "$slug" --reason "resolved" >/dev/null 2>&1 || true

				# Post the approval marker BEFORE removing the label.
				# maintainer-gate.yml checks for <!-- aidevops-signed-approval -->
				# when NMR is removed — if the marker is missing, it re-adds NMR.
				# Also resets the stale-recovery tick counter.
				gh_issue_comment "$issue_num" --repo "$slug" \
					--body "<!-- aidevops-signed-approval -->
<!-- stale-recovery-tick:0 (reset: auto-approved by maintainer — ${approval_reason}) -->
Auto-approved: ${approval_reason}. Stale recovery tick reset." \
					2>/dev/null || true

				gh issue edit "$issue_num" --repo "$slug" \
					--remove-label "needs-maintainer-review" \
					--add-label "auto-dispatch" >/dev/null 2>&1
				local edit_exit=$?
				if [[ "$edit_exit" -eq 0 ]]; then
					echo "[pulse-wrapper] Auto-approved #${issue_num} in ${slug} — ${approval_reason} (locked + approval marker + tick reset)" >>"$LOGFILE"
					total_approved=$((total_approved + 1))
					# t2845: promote knowledge-review source if this is a kind:knowledge-review issue
					_handle_knowledge_review_promotion "$issue_num" "$slug" || true
				else
					echo "[pulse-wrapper] Auto-approve label update FAILED for #${issue_num} in ${slug} (exit: ${edit_exit}) — approval marker posted but labels unchanged" >>"$LOGFILE"
				fi
			fi
		done
	done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | "\(.slug)|\(.maintainer // (.slug | split("/")[0]))"' "$repos_json" 2>/dev/null)

	if [[ "$total_approved" -gt 0 ]]; then
		echo "[pulse-wrapper] Auto-approve maintainer issues: approved ${total_approved} issue(s)" >>"$LOGFILE"
	fi

	return 0
}
