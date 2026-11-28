#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Worker Lifecycle Common -- Escalation Body Gate & No-Work Breaker
# =============================================================================
# Issue-body quality gate used before tier escalation, pagination-safe
# marker counting, the no_work NMR circuit breaker and failure-reason
# classifiers (launch preflight, completion infrastructure, prelaunch skip).
#
# Pure move from worker-lifecycle-common.sh (large-file split, GH#40351):
# function bodies, names and shared variables are unchanged.
#
# Usage: sourced by worker-lifecycle-common.sh; callers keep sourcing that file.
#
# Part of aidevops framework: https://aidevops.sh

# Include guard
[[ -n "${_WORKER_LIFECYCLE_COMMON_ESCALATION_GATE_LOADED:-}" ]] && return 0
_WORKER_LIFECYCLE_COMMON_ESCALATION_GATE_LOADED=1

#######################################
# Detect auto-generated review-feedback issues that already carry bounded
# implementation context even when they do not name a concrete file path.
#
# Source PR + captured review body is enough context for a worker to verify
# whether the review is actionable, already fixed, or scanner noise. Treating
# these as "missing implementation context" strands historical quality-debt
# false positives such as GH#3343 before a higher-tier worker can inspect the
# source review.
#
# Arguments:
#   arg1 - issue body text
# Returns:
#   0 - body contains quality-feedback review context
#   1 - not a quality-feedback review-feedback issue body
#######################################
_escalate_body_has_review_feedback_context() {
	local issue_body="$1"

	case "$issue_body" in
	*"## Unactioned Review Feedback"*) ;;
	*) return 1 ;;
	esac

	case "$issue_body" in
	*"**Source PR**:"*"quality-feedback-helper.sh scan-merged"*) return 0 ;;
	esac

	return 1
}

#######################################
# Detect investigation-ready briefs whose exact write surface is intentionally
# unknown until the investigation runs. Require the complete evidence/plan/test
# shape plus at least one concrete file path and executable verification command;
# headings alone must not bypass the missing-context gate.
#
# Arguments:
#   arg1 - issue body text
# Returns:
#   0 - body contains bounded investigation context
#   1 - investigation context is absent or incomplete
#######################################
_escalate_body_has_investigation_context() {
	local issue_body="$1"
	local heading_pattern=""

	for heading_pattern in \
		'^#{1,6}[[:space:]]+Evidence[[:space:]]*:?[[:space:]]*$' \
		'^#{1,6}[[:space:]]+Files to (inspect|review|investigate)( first)?[[:space:]]*:?[[:space:]]*$' \
		'^#{1,6}[[:space:]]+Approach[[:space:]]*:?[[:space:]]*$' \
		'^#{1,6}[[:space:]]+Acceptance criteria[[:space:]]*:?[[:space:]]*$' \
		'^#{1,6}[[:space:]]+Verification[[:space:]]*:?[[:space:]]*$'; do
		grep -qiE "$heading_pattern" <<<"$issue_body" || return 1
	done

	# A bounded investigation still needs a concrete starting surface.
	grep -qE '[a-zA-Z0-9_.-]+(/[a-zA-Z0-9_.-]+)+\.[a-zA-Z0-9]+' <<<"$issue_body" || return 1
	# Verification must name something executable, not only a prose promise.
	# shellcheck disable=SC2016 # Backticks are literal Markdown delimiters in the regex.
	grep -qE '(^|[[:space:]`])((bash|shellcheck|pytest|python[0-9]*|node|npm|pnpm|yarn|bun|make)[[:space:]]|go[[:space:]]+test([[:space:]]|$)|cargo[[:space:]]+test([[:space:]]|$)|git[[:space:]]+diff([[:space:]]|$)|[.]/|[.][[:alnum:]_/-]+\.sh([[:space:]`]|$))' <<<"$issue_body" || return 1
	return 0
}

#######################################
# Body quality gate for escalate_issue_tier (GH#17561)
# Returns 0 if escalation should proceed, 1 if blocked (posts diagnostic comment).
# Arguments:
#   arg1 - issue number
#   arg2 - repo slug
#   arg3 - failure count
#   arg4 - threshold
#   arg5 - issue body text
#######################################
_escalate_body_quality_gate() {
	local issue_number="$1"
	local repo_slug="$2"
	local failure_count="$3"
	local threshold="$4"
	local issue_body="$5"

	# Empty body — no context to check, allow escalation
	[[ -n "$issue_body" ]] || return 0
	# Review-feedback issues carry Source PR provenance instead of target file
	# paths. Let the tier cascade continue so a stronger worker can verify the
	# source review instead of treating the issue as irreparably under-specified.
	if _escalate_body_has_review_feedback_context "$issue_body"; then
		return 0
	fi
	# Investigation briefs cannot know their final write surface yet. Accept the
	# bounded investigation contract rather than demanding fictional line ranges.
	if _escalate_body_has_investigation_context "$issue_body"; then
		return 0
	fi

	# Check for file path indicators: paths with extensions, EDIT:/NEW: prefixes,
	# backtick-quoted paths, or "Files to Modify" section headers.
	# shellcheck disable=SC2016 # pattern is literal regex; no variable expansion intended
	if grep -qE '(EDIT:|NEW:|`[a-zA-Z0-9_./-]+\.[a-z]+`|Files to Modify|## How|\.sh:|\.py:|\.ts:|\.js:|\.md:)' <<<"$issue_body"; then
		return 0
	fi

	# Body lacks implementation context — post diagnostic instead of escalating
	local diag_body="## Escalation Blocked: Missing Implementation Context

**Trigger:** ${failure_count} consecutive worker failures (threshold: ${threshold})
**Action:** Escalation **skipped** — issue body lacks file paths and implementation steps.

Workers fail when they must explore the entire codebase to find what to change. Adding explicit file paths, reference patterns, and verification commands to the issue body is more effective than escalating to a more expensive model.

**Required:** Update the issue body with one complete context shape:
- **Implementation work:** a \`## How\` section with files to modify, a reference pattern, and verification commands.
- **Investigation work:** \`## Evidence\`, \`## Files to inspect\`, \`## Approach\`, \`## Acceptance criteria\`, and \`## Verification\`, including concrete starting paths and executable checks. Exact modification paths may remain unknown until the investigation completes.

_Automated by \`escalate_issue_tier()\` body quality gate (t1900) in worker-lifecycle-common.sh_"
	# t19356: escalation re-evaluates every failure at or above the threshold;
	# post the diagnostic once, at the threshold itself.
	if [[ "$failure_count" -eq "$threshold" ]]; then
		gh_issue_comment "$issue_number" --repo "$repo_slug" \
			--body "$diag_body" 2>/dev/null || true
	fi
	return 1
}

#######################################
# Count issue comments containing a marker across all paginated comment pages.
#
# Root cause fixed for exampleorg/examplerepo#4007: long issue threads can push
# breaker markers onto page 2+. `gh api --paginate --jq ...` applies jq per
# page instead of across the full comment stream, so a page-local count can
# miss existing t2769 markers and re-file/noise a no_work breaker. Slurping
# all pages before jq keeps marker idempotency consistent with the stale
# activity detector's pagination fix.
#
# Args: $1=issue_number, $2=repo_slug, $3=marker substring
# Stdout: numeric count, or empty on gh/jq failure
# Returns: 0 on count success, 1 on gh/jq failure
#######################################
_count_issue_comments_containing_marker() {
	local issue_number="$1"
	local repo_slug="$2"
	local marker="$3"
	local comments_pages=""
	local count=""

	comments_pages=$(gh api "repos/${repo_slug}/issues/${issue_number}/comments" \
		--paginate --slurp 2>/dev/null) || return 1
	count=$(printf '%s' "$comments_pages" | jq --arg marker "$marker" \
		'[.[] | .[]? | select((.body // "") | contains($marker))] | length' \
		2>/dev/null) || return 1
	printf '%s' "$count"
	return 0
}

#######################################
# t3076: file a root-cause meta-issue with forensics when the no_work
# breaker fires. Idempotent — second trip on the same original is a
# no-op (filer self-checks via marker comment). Best-effort: failures
# are swallowed; status:blocked remains the canonical block on the original.
#
# Args: $1=issue_number, $2=repo_slug, $3=failure_count, $4=reason
# Returns: 0 always
#######################################
_file_circuit_breaker_meta_no_work() {
	local issue_number="$1"
	local repo_slug="$2"
	local failure_count="$3"
	local reason="$4"

	local filer="${SCRIPT_DIR:-${HOME}/.aidevops/agents/scripts}/circuit-breaker-meta-filer.sh"
	[[ -x "$filer" ]] || return 0

	"$filer" file \
		--issue "$issue_number" --repo "$repo_slug" \
		--breaker no_work --failure-count "$failure_count" \
		--reason "$reason" >/dev/null 2>&1 || true
	return 0
}

#######################################
# Post an idempotent diagnostic comment when tier escalation is skipped
# because the worker crashed with crash_type=no_work (infrastructure
# failure — FD exhaustion, plugin init crash, branch naming race, auth
# refresh race). Tier escalation is the wrong response to infra failures:
# a more expensive model cannot fix an FD leak. We keep the issue at its
# current tier, let the next retry attempt run cheaply after the infra
# issue resolves, and rely on the existing circuit breakers to apply
# machine-recoverable structural blocks if retries keep failing.
#
# Idempotent: checks for a prior comment with the marker
# <!-- no-work-escalation-skip --> and skips if present, so a cascade of
# consecutive no_work failures doesn't spam the issue with duplicates.
#
# Arguments:
#   arg1 - issue number
#   arg2 - repo slug (owner/repo)
#   arg3 - failure count (for context)
#   arg4 - kill/failure reason (sanitised)
# Returns: 0 always (best-effort, never fatal)
#######################################
#######################################
# Apply the no_work lifecycle circuit breaker (t2769) when failure_count
# reaches the threshold: idempotent status:blocked state + comment with the
# backward-compatible `cost-circuit-breaker:no_work_loop` marker, then file the
# t3076 root-cause meta-issue.
#
# Args: $1=issue_number, $2=repo_slug, $3=failure_count,
#        $4=legacy-named threshold, $5=reason
# Returns: 0 always (best-effort, never fatal)
#######################################
_apply_no_work_nmr_breaker() {
	local issue_number="$1" repo_slug="$2" failure_count="$3"
	local nmr_threshold="$4" reason="$5"
	local nmr_marker='cost-circuit-breaker:no_work_loop'

	local existing_nmr=""
	existing_nmr=$(_count_issue_comments_containing_marker \
		"$issue_number" "$repo_slug" "$nmr_marker") || existing_nmr=""
	if [[ "$existing_nmr" =~ ^[1-9][0-9]*$ ]]; then
		printf '[worker-lifecycle][t2769] no_work circuit breaker already applied for #%s (%s, count=%s)\n' \
			"$issue_number" "$repo_slug" "$failure_count" >&2 || true
		return 0
	fi

	set_issue_status "$issue_number" "$repo_slug" "$_WLC_STATUS_BLOCKED" 2>/dev/null || true

	local safe_reason
	safe_reason=$(_sanitize_markdown "$reason")

	gh_issue_comment "$issue_number" --repo "$repo_slug" \
		--body "<!-- ${nmr_marker} -->
## no_work Circuit Breaker Fired (t2769)

**Trigger:** ${failure_count} consecutive worker failure(s) classified as \`no_work\` (threshold: ${nmr_threshold}).
**Action:** Applied \`status:blocked\`. Further automated dispatch is suspended.
**Last failure reason:** ${safe_reason}

**Why this class of failure does not cascade tiers:** \`no_work\` usually means the worker crashed during runtime setup before reading any target files (FD exhaustion, plugin init failure, auth refresh race) or stale-recovery falsely concluded no progress. A more expensive model cannot fix an infrastructure problem it never reached.

**Possible causes:**
- Brief not yet merged or branch missing at dispatch time
- Auth token stale or missing
- Plugin init crash (FD exhaustion, env pollution)
- Branch naming race at dispatch time
- Stale-recovery false positive on long issue threads (check dispatch-dedup-stale comment pagination and recent-activity aggregation)

The linked root-cause meta-issue restores \`status:available\` after its fix merges. Manual recovery should requeue only after preserving any worker output.

_Per-issue no_work circuit breaker (t2769). The \`${nmr_marker}\` marker remains backward-compatible evidence for legacy NMR reconciliation._" 2>/dev/null || true

	printf '[worker-lifecycle][t2769] no_work circuit breaker fired for #%s (%s, count=%s)\n' \
		"$issue_number" "$repo_slug" "$failure_count" >&2 || true

	_file_circuit_breaker_meta_no_work "$issue_number" "$repo_slug" \
		"$failure_count" "$reason"
	return 0
}

#######################################
# Detect failures that happened before a worker launch or during launch
# preflight.
#
# These launch-control skips are not evidence that a worker reached the brief,
# so they must not participate in the t2769 per-issue no_work breaker.
# Legitimate post-launch no_work reasons (for example worker_noop_zero_output)
# still flow through the existing breaker path unchanged.
#
# Args: $1=reason
# Returns: 0 when reason is a pre-worker-launch/preflight skip, 1 otherwise.
#######################################
_worker_failure_reason_is_launch_preflight() {
	local reason="${1:-}"

	case "$reason" in
	worker_launch_rc_2 | \
	worker_worktree_live_owner | \
	worktree_live_owner_refused | \
	*":worktree_live_owner_refused" | \
	worker_worktree_continuation_* | \
	worker_worktree_owner_concurrent_mutation | \
	worker_runtime_not_invoked | \
	worker_signing_unavailable | \
	worker_sensitive_temp_preflight_failed | \
	worker_ledger_ready_failed | \
	worker_claim_ready_transition_failed | \
	dispatch_aborted:worker_launch_rc_2 | \
	canary_preflight | \
	*"canary preflight failed"* | \
	*"before worktree pre-creation"* | \
	*"worktree pre-creation failed"* | \
	*"precreation failed"* | \
	*"predispatch_validator_closed"* | \
	*"eligibility_gate"* | \
	*"pre-worker-launch"* | \
	*"pre-launch"*)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

#######################################
# Detect completion-path infrastructure failures where implementation may be
# checkpointed locally and the correct action is resume/completion, not an
# issue-level implementation fast-fail penalty.
# Args: $1=reason
# Returns: 0 for completion infrastructure failures, 1 otherwise.
#######################################
_worker_failure_reason_is_completion_infrastructure() {
	local reason="${1:-}"

	case "$reason" in
	github_api_timeout | command_policy_timeout | prepared_commit_push_blocked | completed_locally_remote_completion_blocked | \
		*"GitHub API timeout"* | *"github api timeout"* | \
		*"command-policy timeout"* | *"command policy timeout"* | \
		*"prepared commit"*"push"*"$_WLC_STATUS_BLOCKED"* | \
		*"completed locally"*"remote completion"*"$_WLC_STATUS_BLOCKED"*)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

#######################################
# GH#40658: per-issue consecutive no_work streak.
#
# Root cause of false t2769 trips: the fast-fail counter handed to
# escalate_issue_tier is cumulative across EVERY non-rate-limit failure class
# (partial, overwhelmed, stale_timeout, watchdog kills, ...). The breaker
# compared that total against NO_WORK_NMR_THRESHOLD, so one no_work failure on
# an issue that already had two real failures blocked it and printed "3
# consecutive no_work failures". The streak below counts only no_work failures
# since the last failure of any other class, matching the breaker's contract.
#
# Storage: one small file per issue ("count epoch") beside the fast-fail state,
# written with tmp+mv. A per-issue file avoids rewriting the shared fast-fail
# JSON from a path that does not hold its lock.
#######################################
_no_work_streak_file() {
	local issue_number="$1"
	local repo_slug="$2"
	local state_file="${FAST_FAIL_STATE_FILE:-${HOME}/.aidevops/.agent-workspace/supervisor/fast-fail-counter.json}"
	local safe_slug="${repo_slug//\//_}"
	printf '%s/no-work-streak/%s_%s' "${state_file%/*}" "$safe_slug" "$issue_number"
	return 0
}

# Print the current streak (0 when absent or expired).
_no_work_streak_get() {
	local issue_number="$1"
	local repo_slug="$2"
	local streak_file="" count="" ts="" now="" expiry="${FAST_FAIL_EXPIRY_SECS:-604800}"
	streak_file=$(_no_work_streak_file "$issue_number" "$repo_slug")
	if [[ -f "$streak_file" ]]; then
		read -r count ts <"$streak_file" 2>/dev/null || true
	fi
	[[ "$count" =~ ^[0-9]+$ ]] || count=0
	[[ "$ts" =~ ^[0-9]+$ ]] || ts=0
	[[ "$expiry" =~ ^[0-9]+$ ]] || expiry=604800
	now=$(date +%s)
	if [[ "$count" -gt 0 && $((now - ts)) -ge "$expiry" ]]; then
		count=0
	fi
	printf '%s' "$count"
	return 0
}

# Increment the streak and print the new value. Best-effort: on write failure
# the incremented value is still printed so the caller never under-reports.
_no_work_streak_bump() {
	local issue_number="$1"
	local repo_slug="$2"
	local streak_file="" current="" next="" tmp_file=""
	current=$(_no_work_streak_get "$issue_number" "$repo_slug")
	next=$((current + 1))
	streak_file=$(_no_work_streak_file "$issue_number" "$repo_slug")
	if mkdir -p "${streak_file%/*}" 2>/dev/null; then
		tmp_file="${streak_file}.tmp.$$"
		if printf '%s %s\n' "$next" "$(date +%s)" >"$tmp_file" 2>/dev/null; then
			mv -f "$tmp_file" "$streak_file" 2>/dev/null || rm -f "$tmp_file" 2>/dev/null || true
		else
			rm -f "$tmp_file" 2>/dev/null || true
		fi
	fi
	printf '%s' "$next"
	return 0
}

# Clear the streak: a failure of another class proves a worker reached the
# brief, and a resolved/reset issue starts a fresh count.
_no_work_streak_reset() {
	local issue_number="$1"
	local repo_slug="$2"
	local streak_file=""
	streak_file=$(_no_work_streak_file "$issue_number" "$repo_slug")
	rm -f "$streak_file" 2>/dev/null || true
	return 0
}

#######################################
# Resolve the failure count the no_work breaker must compare to its threshold.
# Pre-launch/completion-infrastructure reasons never count (the breaker skips
# them), so they pass the caller's count through untouched.
# Args: $1=issue_number, $2=repo_slug, $3=cumulative failure_count, $4=reason
# Stdout: consecutive no_work count
#######################################
_no_work_effective_failure_count() {
	local issue_number="$1"
	local repo_slug="$2"
	local failure_count="$3"
	local reason="${4:-}"

	if _no_work_reason_is_prelaunch_skip "$reason"; then
		printf '%s' "$failure_count"
		return 0
	fi
	_no_work_streak_bump "$issue_number" "$repo_slug"
	return 0
}

_no_work_reason_is_prelaunch_skip() {
	local reason="${1:-}"
	# Completion-path infrastructure failures (GitHub API / command-policy
	# timeouts, blocked push of a prepared commit) happen AFTER the worker read
	# the brief and may hold a local checkpoint. The fast-fail recorder already
	# skips them; the breaker must too, or escalate_issue_tier(crash_type=no_work)
	# can trip t2769 on work that was actually done (GH#38752).
	if _worker_failure_reason_is_launch_preflight "$reason" ||
		_worker_failure_reason_is_completion_infrastructure "$reason"; then
		return 0
	fi
	return 1
}

_log_no_work_skip_escalation() {
	local issue_number="$1"
	local repo_slug="$2"
	local failure_count="$3"
	local reason="${4:-worker_exited_before_reading_brief}"

	[[ "$issue_number" =~ ^[0-9]+$ ]] || return 0
	[[ -n "$repo_slug" ]] || return 0

	local nmr_threshold="${NO_WORK_NMR_THRESHOLD:-3}"

	if _no_work_reason_is_prelaunch_skip "$reason"; then
		printf '[worker-lifecycle][t2769] no_work breaker skipped for pre-launch reason on #%s (%s, count=%s): %s\n' \
			"$issue_number" "$repo_slug" "$failure_count" "$reason" >&2 || true
		return 0
	fi

	# Circuit-breaker path (t2769): when failure_count >= threshold,
	# apply status:blocked + file a root-cause meta-issue.
	if [[ "$failure_count" -ge "$nmr_threshold" ]]; then
		_apply_no_work_nmr_breaker "$issue_number" "$repo_slug" \
			"$failure_count" "$nmr_threshold" "$reason"
		return 0
	fi

	# Below threshold: idempotent diagnostic comment (existing t2387 behaviour).
	local marker='<!-- no-work-escalation-skip -->'

	# Idempotency check: skip if a prior comment already carries the marker.
	# Best-effort — if gh api fails, fall through and post (better to repeat
	# once than to lose the diagnostic entirely).
	local existing=""
	existing=$(_count_issue_comments_containing_marker \
		"$issue_number" "$repo_slug" "$marker") || existing=""
	if [[ "$existing" =~ ^[1-9][0-9]*$ ]]; then
		# Already posted once — nothing more to do. Still emit a one-line
		# log so operators can track the skip rate if they're tailing logs.
		printf '[worker-lifecycle][t2387] no_work skip-escalation already recorded for #%s (%s, count=%s)\n' \
			"$issue_number" "$repo_slug" "$failure_count" >&2 || true
		return 0
	fi

	local safe_reason
	safe_reason=$(_sanitize_markdown "$reason")

	local comment_body="<!-- ops:start — workers: skip this comment, it is audit trail not implementation context -->
${marker}
## Tier Escalation Skipped: Infrastructure Failure (no_work)

**Trigger:** ${failure_count} worker failure(s) classified as \`no_work\` — the worker exited during setup without reading any target files.
**Action:** Tier escalation **skipped**. The issue stays at its current tier so the next retry can succeed cheaply once the infrastructure issue resolves.
**Reason:** ${safe_reason}

**Why no cascade:** \`no_work\` means the worker never produced reliable implementation evidence — it crashed during runtime setup (FD exhaustion, plugin init failure, branch naming race, auth refresh race) or stale-recovery falsely concluded no progress. A more expensive model cannot fix an infrastructure problem it never reached. Cascading to \`tier:thinking\` would waste capacity on a problem the mapped standard or simple model can handle once the infrastructure clears.

After ${nmr_threshold} consecutive \`no_work\` failures the per-issue no_work circuit breaker (t2769) applies \`status:blocked\` and files a machine-recoverable root-cause meta-issue.

_Automated by \`escalate_issue_tier()\` no_work skip (t2387) in worker-lifecycle-common.sh_
<!-- ops:end -->"

	gh_issue_comment "$issue_number" --repo "$repo_slug" \
		--body "$comment_body" 2>/dev/null || true

	printf '[worker-lifecycle][t2387] no_work skip-escalation posted for #%s (%s, count=%s)\n' \
		"$issue_number" "$repo_slug" "$failure_count" >&2 || true
	return 0
}
