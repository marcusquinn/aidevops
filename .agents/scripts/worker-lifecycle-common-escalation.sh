#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Worker Lifecycle Common -- Tier Escalation
# =============================================================================
# Escalation thresholds, no_work reclassification (t2820) and the
# escalate_issue_tier cascade (simple -> standard -> thinking).
#
# Pure move from worker-lifecycle-common.sh (large-file split, GH#40351):
# function bodies, names and shared variables are unchanged.
#
# Usage: sourced by worker-lifecycle-common.sh; callers keep sourcing that file.
#
# Part of aidevops framework: https://aidevops.sh

# Include guard
[[ -n "${_WORKER_LIFECYCLE_COMMON_ESCALATION_LOADED:-}" ]] && return 0
_WORKER_LIFECYCLE_COMMON_ESCALATION_LOADED=1

#######################################
# Escalate issue model tier after repeated worker failures.
#
# Cascade escalation: tier:simple → tier:standard → tier:thinking.
# Crash-type-aware thresholds determine when escalation fires:
#   - "overwhelmed": model read files, attempted work, but couldn't complete
#     → simple -> standard escalates immediately (threshold=1). Escalation
#     into thinking still needs ESCALATION_THINKING_MIN_FAILURES (default 2,
#     t19356): the most expensive tier is earned by repeated failure.
#   - "no_work": infrastructure failure (FD exhaustion, plugin init crash,
#     auth refresh race). **Short-circuits BEFORE tier cascade** (t2387) —
#     a more expensive model cannot fix infrastructure. Keeps the issue
#     at its current tier and posts a diagnostic comment via
#     _log_no_work_skip_escalation; existing circuit breakers apply structural
#     status blocks on cost/staleness thresholds if retries persist.
#   - "partial" / other: default threshold (2). Model got partway, may
#     succeed with a continuation or fresh attempt.
#
# If already at tier:thinking, no further escalation — the issue stays
# for the needs-human path.
#
# Each escalation posts a structured report to the issue so the next
# tier starts with accumulated context, not from zero.
#
# Arguments:
#   arg1 - issue number
#   arg2 - repo slug (owner/repo)
#   arg3 - failure count (current fast-fail count AFTER increment)
#   arg4 - kill/failure reason (for the comment)
#   arg5 - crash type: "overwhelmed" | "no_work" | "partial" | "" (optional)
# Returns: 0 always (best-effort, never fatal)
#######################################
ESCALATION_FAILURE_THRESHOLD="${ESCALATION_FAILURE_THRESHOLD:-2}"
ESCALATION_OVERWHELMED_THRESHOLD="${ESCALATION_OVERWHELMED_THRESHOLD:-1}"
# t19356: escalation INTO tier:thinking (the most expensive model) needs at
# least this many failures in the issue's fast-fail window, whatever the crash
# type. One overwhelmed run (most often worker_post_pr_handoff_unverified) is
# not evidence that the standard model cannot do the task; repeated failure is.
ESCALATION_THINKING_MIN_FAILURES="${ESCALATION_THINKING_MIN_FAILURES:-2}"
NO_WORK_NMR_THRESHOLD="${NO_WORK_NMR_THRESHOLD:-3}"
# t2820: maximum log-file age (seconds) under which a `worker_failed` event
# with no tool-call markers in the log tail will be reclassified as `no_work`.
# Workers that ran for longer are likely real coding failures (worker engaged,
# read files, attempted edits) where escalation IS appropriate. The default
# (180s) is conservative — most real coding work produces tool-call frames in
# the first minute. Override via env when investigating specific incidents.
NO_WORK_RECLASS_ELAPSED_MAX="${NO_WORK_RECLASS_ELAPSED_MAX:-180}"

#######################################
# Record one no_work failure for the t2769 breaker (GH#40658). The breaker
# counts consecutive no_work failures, not the cumulative fast-fail total
# across every failure class.
# Args: $1=issue_number, $2=repo_slug, $3=cumulative failure_count, $4=reason
#######################################
_escalate_record_no_work() {
	local issue_number="$1"
	local repo_slug="$2"
	local failure_count="$3"
	local reason="$4"
	local no_work_count=""

	no_work_count=$(_no_work_effective_failure_count "$issue_number" \
		"$repo_slug" "$failure_count" "$reason")
	_log_no_work_skip_escalation "$issue_number" "$repo_slug" \
		"$no_work_count" "$reason"
	return 0
}

#######################################
# _maybe_reclassify_worker_failed_as_no_work — Phase 5 reclassification (t2820)
#
# When `escalate_issue_tier` is called with `crash_type == ""` and a
# `worker_failed`-class reason, inspect the worker log tail to decide whether
# this is a genuine coding failure (escalate) or a late infra failure that the
# pulse currently mis-classifies (`worker_failed` is the catch-all bucket — see
# issue body for the false-merge background).
#
# Reclassification rules (in order of precedence):
#
#   1. Log tail contains canary diagnostics OR `[t2814:early_exit]` marker
#      → reclassify as `no_work` with subtype `canary_post_spawn_failure`.
#      The worker spawned but died before any real work — opus cannot help.
#
#   2. Log file age <= NO_WORK_RECLASS_ELAPSED_MAX AND log tail contains no
#      tool-use markers → reclassify as `no_work` with subtype
#      `no_tool_calls_in_log`. The worker was alive long enough to run, but
#      never reached implementation. Same opus-cannot-help reasoning.
#
#   3. Otherwise (real_coding signals, log too old, or log missing) → no
#      reclassification. Caller's existing escalation logic runs unchanged.
#
# When a rule fires, the helper invokes `_log_no_work_skip_escalation` with
# the subtype embedded in the `reason` arg so the diagnostic comment explains
# which rule fired. Returns 0 to signal "reclassified, skip cascade"; returns
# 1 to signal "fall through to normal escalation".
#
# Args:
#   $1 - issue_number
#   $2 - repo_slug
#   $3 - failure_count
#   $4 - original reason (e.g. worker_failed, premature_exit)
#
# Returns: 0 on reclassification (caller MUST short-circuit), 1 otherwise.
#######################################
_maybe_reclassify_worker_failed_as_no_work() {
	local issue_number="$1"
	local repo_slug="$2"
	local failure_count="$3"
	local original_reason="$4"

	# Only reclassify worker_failed-class reasons. Rate-limit and explicit
	# crash_type cases are handled elsewhere; we should not touch them.
	#
	# Reasons that map to "spawned but produced no useful output":
	#   - worker_failed             (catch-all from headless-runtime-helper)
	#   - premature_exit            (watchdog-detected early exit)
	#   - worker_noop_zero_output   (post-completion zero-output check)
	case "$original_reason" in
	worker_failed | premature_exit | worker_noop_zero_output) ;;
	*) return 1 ;;
	esac

	# Need the shared log-tail reader. If not loaded, fall through — better
	# to escalate normally than to mis-classify on missing tooling.
	if ! declare -F _read_worker_log_tail_classified >/dev/null 2>&1; then
		return 1
	fi

	# Reset caller-scope vars (the reader resets them too, but be explicit).
	_WORKER_LOG_TAIL_FILE=""
	_WORKER_LOG_TAIL_CONTENT=""
	_WORKER_LOG_TAIL_CLASS="unknown"
	_WORKER_LOG_TAIL_AGE_SECS=""

	_read_worker_log_tail_classified "$issue_number" "$repo_slug"

	# Design constraint (per issue body): if Phase 3's log-tail data is
	# absent (older dispatch records, log file rotated away), fall through
	# to existing worker_failed → escalation behaviour unchanged. No
	# regression on pre-Phase 3 records.
	[[ -n "${_WORKER_LOG_TAIL_FILE:-}" ]] || return 1
	[[ "${_WORKER_LOG_TAIL_CLASS:-unknown}" != "unknown" ]] || return 1

	local subtype=""
	case "$_WORKER_LOG_TAIL_CLASS" in
	canary_post_spawn)
		# Highest-precedence rule: explicit infra-failure markers in the
		# log tail. Fire regardless of runtime — a canary-failure tail
		# 10 minutes after spawn is still a canary failure.
		subtype="canary_post_spawn_failure"
		;;
	no_tool_calls)
		# Runtime-bounded rule: only reclassify when the log file is
		# young enough that "no tool calls" credibly means "didn't get
		# to coding". For longer runtimes, the worker may have legitimately
		# coded and only the tail visible (a 20-line tail at 30 minutes
		# of runtime can easily miss the implementation phase).
		local age="${_WORKER_LOG_TAIL_AGE_SECS:-}"
		if [[ -n "$age" && "$age" =~ ^[0-9]+$ \
			&& "$age" -le "$NO_WORK_RECLASS_ELAPSED_MAX" ]]; then
			subtype="no_tool_calls_in_log"
		fi
		;;
	real_coding)
		# Worker did real implementation work. Original escalation is
		# the right response.
		return 1
		;;
	esac

	# No subtype assigned → no reclassification (e.g. no_tool_calls but
	# log too old). Fall through to normal escalation.
	[[ -n "$subtype" ]] || return 1

	# Compose the reason that will appear in the skip-escalation comment.
	# Prefix with the subtype so operators can grep for the specific rule
	# that fired (auditable per the issue's verification example).
	local reclass_reason="no_work:${subtype} (reclassified from ${original_reason} via log-tail at ${_WORKER_LOG_TAIL_FILE})"

	# Single-line audit log for log tailers — keeps the reclassification
	# observable even when the GH comment fails to post.
	printf '[worker-lifecycle][t2820] reclassified worker_failed→no_work for #%s (%s) subtype=%s age=%ss class=%s\n' \
		"$issue_number" "$repo_slug" "$subtype" \
		"${_WORKER_LOG_TAIL_AGE_SECS:-?}" "${_WORKER_LOG_TAIL_CLASS}" >&2 || true

	_escalate_record_no_work "$issue_number" "$repo_slug" \
		"$failure_count" "$reclass_reason"
	return 0
}

_resolve_escalation_threshold() {
	local crash_type="$1"
	local threshold="$ESCALATION_FAILURE_THRESHOLD"
	if [[ "$crash_type" == "overwhelmed" ]]; then
		threshold="$ESCALATION_OVERWHELMED_THRESHOLD"
	fi
	[[ "$threshold" =~ ^[0-9]+$ ]] || threshold=2
	[[ "$threshold" -ge 1 ]] || threshold=2
	printf '%s\n' "$threshold"
	return 0
}

# t19356: failures required before moving to next_tier. Escalation into
# thinking needs at least ESCALATION_THINKING_MIN_FAILURES (default 2).
_resolve_tier_required_failures() {
	local base_threshold="$1"
	local next_tier="$2"
	local required="$base_threshold"
	if [[ "$next_tier" == "thinking" ]]; then
		local thinking_min="$ESCALATION_THINKING_MIN_FAILURES"
		[[ "$thinking_min" =~ ^[0-9]+$ && "$thinking_min" -ge 1 ]] || thinking_min=2
		[[ "$thinking_min" -gt "$required" ]] && required="$thinking_min"
	fi
	printf '%s\n' "$required"
	return 0
}

# t19356: a PR already exists for these reasons; the failure is in the
# review/handoff lifecycle, which a more expensive model cannot fix. Matches
# _fast_fail_reason_wants_enrichment, which skips the same family.
_escalation_reason_is_pr_handoff() {
	local reason="$1"
	case "$reason" in
	worker_post_pr_handoff_* | worker_closed_unmerged_pr | worker_ready_missing_*)
		return 0
		;;
	esac
	return 1
}

_resolve_next_escalation_tier() {
	local current_labels="$1"
	case ",$current_labels," in
	*,tier:thinking,*) return 1 ;;
	*,tier:standard,*)
		printf '%s\n' 'standard|thinking|tier:thinking|tier:standard'
		;;
	*,tier:simple,*)
		printf '%s\n' 'simple|standard|tier:standard|tier:simple'
		;;
	*)
		printf '%s\n' 'standard|thinking|tier:thinking|'
		;;
	esac
	return 0
}

_apply_tier_escalation_label() {
	local issue_number="$1"
	local repo_slug="$2"
	local next_label="$3"
	local remove_label="$4"
	local label_desc=""
	local label_color=""

	case "$next_label" in
	tier:thinking)
		label_desc="Route at the thinking workload tier"
		label_color="7057FF"
		;;
	tier:standard)
		label_desc="Route at the standard workload tier"
		label_color="0E8A16"
		;;
	esac

	gh label create "$next_label" --repo "$repo_slug" \
		--description "$label_desc" --color "$label_color" \
		--force 2>/dev/null || true

	local edit_args="--add-label $next_label"
	if [[ -n "$remove_label" ]]; then
		edit_args="$edit_args --remove-label $remove_label"
	fi
	# shellcheck disable=SC2086
	gh issue edit "$issue_number" --repo "$repo_slug" \
		$edit_args 2>/dev/null || return 1
	return 0
}

_post_tier_escalation() {
	local issue_number="$1"
	local repo_slug="$2"
	local failure_count="$3"
	local threshold="$4"
	local current_tier="$5"
	local next_tier="$6"
	local next_label="$7"
	local safe_reason="$8"
	local crash_type="$9"
	local crash_type_label=""

	case "$crash_type" in
	overwhelmed)
		crash_type_label="**Crash type:** \`overwhelmed\` — model read target files and attempted implementation but could not produce commits. Escalation threshold: ${threshold}."
		;;
	partial)
		crash_type_label="**Crash type:** \`partial\` — worker produced commits but could not complete the PR lifecycle."
		;;
	esac

	local comment_body="## Cascade Tier Escalation: tier:${current_tier} → tier:${next_tier}

**Trigger:** ${failure_count} consecutive worker failures at \`tier:${current_tier}\` (threshold: ${threshold})
**Action:** Added \`${next_label}\` label — next dispatch will use ${next_tier}-tier model.
**Reason:** ${safe_reason}
${crash_type_label:+${crash_type_label}
}
Previous attempts at \`tier:${current_tier}\` failed to produce a PR. Escalating to a more capable model.

The next worker receives validated prior-attempt state and sanitised failure signals in its dispatch prompt; it should work from the issue body and current repository state, not from operational comments like this one.

_Automated by \`escalate_issue_tier()\` cascade dispatch in worker-lifecycle-common.sh_"

	gh_issue_comment "$issue_number" --repo "$repo_slug" \
		--body "$comment_body" 2>/dev/null || true

	local ledger_helper="${HOME}/.aidevops/agents/scripts/dispatch-ledger-helper.sh"
	if [[ -x "$ledger_helper" ]]; then
		"$ledger_helper" record-outcome \
			--issue "$issue_number" --repo "$repo_slug" \
			--session-key "issue-${issue_number}" \
			--outcome "escalated" --tier "$current_tier" \
			--reason "$safe_reason" 2>/dev/null || true
	fi
	return 0
}

escalate_issue_tier() {
	local issue_number="$1"
	local repo_slug="$2"
	local failure_count="$3"
	local reason="${4:-repeated_failure}"
	local crash_type="${5:-}"

	[[ "$issue_number" =~ ^[0-9]+$ ]] || return 0
	[[ -n "$repo_slug" ]] || return 0
	[[ "$failure_count" =~ ^[0-9]+$ ]] || return 0

	if [[ -z "$crash_type" ]]; then
		if _maybe_reclassify_worker_failed_as_no_work \
			"$issue_number" "$repo_slug" "$failure_count" "$reason"; then
			return 0
		fi
	fi

	local threshold
	threshold=$(_resolve_escalation_threshold "$crash_type")

	# t2387: no_work crashes are infrastructure failures (FD exhaustion,
	# plugin init crash, branch naming race, auth refresh race). A more
	# expensive model cannot fix those, so skip the tier cascade and keep the
	# current tier; the circuit-breaker helpers apply structural blocks if
	# retries keep failing. This early return also subsumes the t2119
	# body-quality-gate skip for no_work crashes.
	if [[ "$crash_type" == "no_work" ]]; then
		_escalate_record_no_work "$issue_number" "$repo_slug" "$failure_count" "$reason"
		return 0
	fi
	# GH#40658: another failure class proves a worker reached the brief.
	_no_work_streak_reset "$issue_number" "$repo_slug"

	# t19356: the fast-fail count is cumulative per issue, so an issue that
	# moved simple -> standard must still reach the (higher) thinking
	# threshold later. Compare with -ge; the tier labels keep it idempotent.
	[[ "$failure_count" -ge "$threshold" ]] || return 0

	local current_labels
	current_labels=$(gh issue view "$issue_number" --repo "$repo_slug" \
		--json labels --jq '[.labels[].name] | join(",")' 2>/dev/null) || current_labels=""
	local tier_route
	tier_route=$(_resolve_next_escalation_tier "$current_labels") || return 0
	local current_tier=""
	local next_tier=""
	local next_label=""
	local remove_label=""
	IFS='|' read -r current_tier next_tier next_label remove_label <<<"$tier_route"
	threshold=$(_resolve_tier_required_failures "$threshold" "$next_tier")
	if [[ "$failure_count" -lt "$threshold" ]]; then
		printf '[worker-lifecycle][t19356] #%s (%s) stays %s: %s/%s failures before %s escalation\n' \
			"$issue_number" "$repo_slug" "${current_tier:-unlabelled}" \
			"$failure_count" "$threshold" "$next_tier" >&2 || true
		return 0
	fi
	if [[ "$next_tier" == "thinking" ]] && _escalation_reason_is_pr_handoff "$reason"; then
		printf '[worker-lifecycle][t19356] #%s (%s) stays %s: %s is a PR handoff failure, not capability evidence\n' \
			"$issue_number" "$repo_slug" "${current_tier:-unlabelled}" "$reason" >&2 || true
		return 0
	fi

	# Body quality gate (t1900): check if the issue body has implementation
	# context before escalating. If the body lacks file paths, the root cause
	# is a vague issue — not model capability. Escalating wastes a more
	# expensive model on the same exploration problem.
	#
	# Note: t2119 originally added an inline `crash_type != "no_work"` guard
	# here so no_work crashes would bypass the body-gate. That guard was
	# removed by t2387 when the entire function gained an earlier
	# `crash_type == "no_work"` short-circuit that returns before reaching
	# this point — so only overwhelmed / partial / unclassified reach here,
	# and every path through the function that gets here wants the gate
	# evaluated.
	local issue_body
	issue_body=$(gh issue view "$issue_number" --repo "$repo_slug" \
		--json body --jq '.body // ""' 2>/dev/null) || issue_body=""
	_escalate_body_quality_gate "$issue_number" "$repo_slug" \
		"$failure_count" "$threshold" "$issue_body" || return 0

	_apply_tier_escalation_label "$issue_number" "$repo_slug" \
		"$next_label" "$remove_label" || return 0

	local safe_reason
	safe_reason=$(_sanitize_markdown "$reason")
	_post_tier_escalation "$issue_number" "$repo_slug" "$failure_count" \
		"$threshold" "$current_tier" "$next_tier" "$next_label" \
		"$safe_reason" "$crash_type"

	return 0
}
