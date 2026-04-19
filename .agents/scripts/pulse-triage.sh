#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-triage.sh — Triage dedup + consolidation helpers — content-hash dedup cache, bot-skip detection, idempotent gh-comment helper, issue-consolidation label reevaluation.
#
# Extracted from pulse-wrapper.sh in Phase 8 (parent: GH#18356,
# plan: todo/plans/pulse-wrapper-decomposition.md §6).
#
# Must be sourced from pulse-wrapper.sh. Depends on shared-constants.sh
# and worker-lifecycle-common.sh being sourced first by the orchestrator.
#
# Functions in this module (in source order):
#   - _triage_content_hash
#   - _triage_is_cached
#   - _triage_update_cache
#   - _triage_increment_failure
#   - _triage_awaiting_contributor_reply
#   - _gh_idempotent_comment
#   - _issue_needs_consolidation
#   - _reevaluate_consolidation_labels
#   - _reevaluate_simplification_labels
#   - _consolidation_child_exists        (t1982)
#   - _consolidation_substantive_comments (t1982)
#   - _format_consolidation_comments_section (t1982)
#   - _compose_consolidation_worker_instructions (t1982)
#   - _compose_consolidation_child_body  (t1982)
#   - _ensure_consolidation_labels       (t1982)
#   - _create_consolidation_child_issue  (t1982)
#   - _post_consolidation_dispatch_comment (t1982)
#   - _dispatch_issue_consolidation
#   - _backfill_stale_consolidation_labels (t1982)

[[ -n "${_PULSE_TRIAGE_LOADED:-}" ]] && return 0
_PULSE_TRIAGE_LOADED=1

# Module-level defaults — single source of truth for consolidation gate thresholds.
# := form: env overrides set before sourcing this module still take effect;
# these only apply when the variable is unset. Avoids duplicate-default drift
# between pulse-wrapper.sh and inline guards. Aligns all call sites to the same
# 500-char minimum and threshold=2, eliminating the 200-vs-500 mismatch.
: "${ISSUE_CONSOLIDATION_COMMENT_THRESHOLD:=2}"
: "${ISSUE_CONSOLIDATION_COMMENT_MIN_CHARS:=500}"

# t2151: Cross-runner advisory lock TTL for consolidation dispatch. If a
# `consolidation-in-progress` label stays applied longer than this many hours
# without being naturally released (by successful child creation + release,
# or by release-on-child-close), the backfill pass clears it. Prevents a
# crashed runner from permanently wedging the parent behind a stale lock.
#
# Default 6h: long enough to absorb GitHub API outages, slow runners, and
# operator intervention windows; short enough that a truly stuck lock gets
# cleared within one working day rather than accumulating.
#
# t2151: Grace period after lock acquisition during which a re-check of
# the comment-based tiebreaker is suppressed. The tiebreaker comment is
# posted immediately after the label; a tight re-read racing against the
# caller's own comment would see its own marker plus the competitor's and
# pick a winner before either runner has flushed its child-creation API
# call. 2s is comfortably longer than the single-writer path (label + comment
# + child-create = ~0.3-0.8s in normal conditions) and short enough that
# operator latency is imperceptible.
: "${CONSOLIDATION_LOCK_TTL_HOURS:=6}"
: "${CONSOLIDATION_LOCK_TIEBREAK_WAIT_SEC:=2}"

# Compute a content hash from issue body + human comments.
# Excludes github-actions[bot] comments and our own triage reviews
# (## Review: prefix) so that only author/contributor changes trigger
# a re-triage.
#
# Args: $1=issue_num, $2=repo_slug, $3=body (pre-fetched), $4=comments_json (pre-fetched)
# Outputs: sha256 hash to stdout
_triage_content_hash() {
	local issue_num="$1"
	local repo_slug="$2"
	local body="$3"
	local comments_json="$4"

	# Filter to human comments: exclude github-actions[bot] and triage reviews.
	# GH#17873: Match broader review header pattern (## *Review*) to exclude
	# reviews posted with variant headers, consistent with the extraction regex.
	local human_comments=""
	human_comments=$(printf '%s' "$comments_json" | jq -r \
		'[.[] | select(.author != "github-actions[bot]" and .author != "github-actions") | select(.body | test("^## .*[Rr]eview") | not) | .body] | join("\n---\n")' \
		2>/dev/null) || human_comments=""

	printf '%s\n%s' "$body" "$human_comments" | shasum -a 256 | cut -d' ' -f1
	return 0
}

# Check if triage content hash matches the cached value.
# Returns 0 if content is unchanged (skip triage), 1 if changed or uncached.
#
# Args: $1=issue_num, $2=repo_slug, $3=current_hash
_triage_is_cached() {
	local issue_num="$1"
	local repo_slug="$2"
	local current_hash="$3"
	local slug_safe="${repo_slug//\//_}"
	local cache_file="${TRIAGE_CACHE_DIR}/${slug_safe}-${issue_num}.hash"

	[[ -f "$cache_file" ]] || return 1

	local cached_hash=""
	cached_hash=$(cat "$cache_file" 2>/dev/null) || return 1
	[[ "$cached_hash" == "$current_hash" ]] && return 0
	return 1
}

# Update the triage content hash cache after a triage attempt.
#
# Args: $1=issue_num, $2=repo_slug, $3=content_hash
_triage_update_cache() {
	local issue_num="$1"
	local repo_slug="$2"
	local content_hash="$3"
	local slug_safe="${repo_slug//\//_}"

	mkdir -p "$TRIAGE_CACHE_DIR" 2>/dev/null || true
	printf '%s' "$content_hash" >"${TRIAGE_CACHE_DIR}/${slug_safe}-${issue_num}.hash" 2>/dev/null || true
	# Reset failure counter on successful cache write
	rm -f "${TRIAGE_CACHE_DIR}/${slug_safe}-${issue_num}.failures" 2>/dev/null || true
	return 0
}

# Increment failure counter and return whether retry cap is reached.
# Returns 0 if cap reached (should cache anyway), 1 if retries remain.
#
# Args: $1=issue_num, $2=repo_slug, $3=content_hash
_triage_increment_failure() {
	local issue_num="$1"
	local repo_slug="$2"
	local content_hash="$3"
	local slug_safe="${repo_slug//\//_}"
	local fail_file="${TRIAGE_CACHE_DIR}/${slug_safe}-${issue_num}.failures"

	mkdir -p "$TRIAGE_CACHE_DIR" 2>/dev/null || true

	local current_count=0
	local stored_hash=""
	if [[ -f "$fail_file" ]]; then
		# Format: "hash:count"
		stored_hash=$(cut -d: -f1 "$fail_file" 2>/dev/null) || stored_hash=""
		current_count=$(cut -d: -f2 "$fail_file" 2>/dev/null) || current_count=0
		# Reset counter if hash changed (new content since last failure)
		if [[ "$stored_hash" != "$content_hash" ]]; then
			current_count=0
		fi
	fi

	current_count=$((current_count + 1))
	printf '%s:%d' "$content_hash" "$current_count" >"$fail_file" 2>/dev/null || true

	if [[ "$current_count" -ge "$TRIAGE_MAX_RETRIES" ]]; then
		return 0
	fi
	return 1
}

#######################################
# GH#17827: Check if an NMR issue is awaiting a contributor reply.
#
# When the last human comment on an NMR issue is from a repo collaborator
# (maintainer asking for clarification), the ball is in the contributor's
# court. Triage adds no value — the issue needs the contributor to respond,
# not another automated review. Skipping triage here avoids the lock/unlock
# noise entirely.
#
# Args: $1=issue_comments (JSON array from gh api)
#       $2=repo_slug
# Returns: 0 if awaiting contributor reply (skip triage), 1 otherwise
#######################################
_triage_awaiting_contributor_reply() {
	local issue_comments="$1"
	local repo_slug="$2"

	# Get the last human comment (exclude bots and triage reviews)
	local last_human_author=""
	last_human_author=$(printf '%s' "$issue_comments" | jq -r \
		'[.[] | select(.author != "github-actions[bot]" and .author != "github-actions") | select(.body | test("^## .*[Rr]eview") | not)] | last | .author // ""' \
		2>/dev/null) || last_human_author=""

	[[ -n "$last_human_author" ]] || return 1

	# Check if the last commenter is a repo collaborator (maintainer/member)
	local perm_level=""
	perm_level=$(gh api "repos/${repo_slug}/collaborators/${last_human_author}/permission" \
		--jq '.permission // ""' 2>/dev/null) || perm_level=""

	case "$perm_level" in
	admin | maintain | write)
		# Last comment is from a collaborator — awaiting contributor reply
		return 0
		;;
	esac

	return 1
}

#######################################
# Idempotent comment posting: race-safe primitive for gate comments.
#
# Multiple pulse instances (different maintainers/machines) can race
# when posting gate comments (consolidation, simplification, blocker).
# Label-only guards have a TOCTOU window: both pulses read "no label",
# both post, producing duplicate comments (observed: GH#17898).
#
# This function checks existing comments for a marker string before
# posting. Fails closed on API errors (never posts if it can't confirm
# the comment is absent).
#
# Arguments:
#   $1 - entity_number (issue or PR number)
#   $2 - repo_slug (owner/repo)
#   $3 - marker (unique string to grep for in existing comments)
#   $4 - comment_body (full comment text to post)
#   $5 - entity_type ("issue" or "pr", default "issue")
#
# Returns:
#   0 - comment posted successfully OR already existed (idempotent)
#   1 - API error fetching comments (fail-closed, caller should retry)
#   2 - missing arguments
#
# Usage:
#   _gh_idempotent_comment "$issue_number" "$repo_slug" \
#       "## Issue Consolidation Needed" "$comment_body"
#######################################
_gh_idempotent_comment() {
	local entity_number="$1"
	local repo_slug="$2"
	local marker="$3"
	local comment_body="$4"
	local entity_type="${5:-issue}"

	if [[ -z "$entity_number" || -z "$repo_slug" || -z "$marker" || -z "$comment_body" ]]; then
		echo "[pulse-wrapper] _gh_idempotent_comment: missing arguments (entity=$entity_number repo=$repo_slug marker_len=${#marker})" >>"$LOGFILE"
		return 2
	fi

	# Fetch existing comments and check for marker.
	# Use the REST API for issues; gh pr view for PRs.
	local existing_comments=""
	if [[ "$entity_type" == "pr" ]]; then
		existing_comments=$(gh pr view "$entity_number" --repo "$repo_slug" \
			--json comments --jq '.comments[].body' 2>/dev/null)
	else
		existing_comments=$(gh api "repos/${repo_slug}/issues/${entity_number}/comments" \
			--jq '.[].body' 2>/dev/null)
	fi
	local api_exit=$?

	if [[ $api_exit -ne 0 ]]; then
		# API error — fail closed. Never post when we can't confirm absence.
		echo "[pulse-wrapper] _gh_idempotent_comment: API error (exit=$api_exit) fetching comments for #${entity_number} in ${repo_slug} — skipping (fail closed)" >>"$LOGFILE"
		return 1
	fi

	# Check if marker already exists in any comment
	if printf '%s' "$existing_comments" | grep -qF "$marker"; then
		echo "[pulse-wrapper] _gh_idempotent_comment: marker already present on #${entity_number} in ${repo_slug} — skipping duplicate" >>"$LOGFILE"
		return 0
	fi

	# Marker not found — safe to post
	# t2393: route through gh_{issue,pr}_comment wrappers for sig footer.
	if [[ "$entity_type" == "pr" ]]; then
		gh_pr_comment "$entity_number" --repo "$repo_slug" \
			--body "$comment_body" 2>/dev/null || true
	else
		gh_issue_comment "$entity_number" --repo "$repo_slug" \
			--body "$comment_body" 2>/dev/null || true
	fi

	echo "[pulse-wrapper] _gh_idempotent_comment: posted gate comment on #${entity_number} in ${repo_slug} (marker: ${marker:0:40}...)" >>"$LOGFILE"
	return 0
}

# t2161: Idempotently remove the `needs-consolidation` label from an issue
# and log the reason. Used by `_issue_needs_consolidation`'s two auto-clear
# branches (in-flight resolving PR + post-filter substantive_count drop).
# Extracted to keep the parent function under the per-function complexity
# threshold. Args: $1=issue_number $2=repo_slug $3=reason (free-text).
_clear_needs_consolidation_label() {
	local issue_number="$1"
	local repo_slug="$2"
	local reason="$3"
	gh issue edit "$issue_number" --repo "$repo_slug" \
		--remove-label "needs-consolidation" >/dev/null 2>&1 || true
	echo "[pulse-wrapper] Consolidation gate cleared for #${issue_number} (${repo_slug}) — ${reason}" >>"$LOGFILE"
	return 0
}

_issue_needs_consolidation() {
	local issue_number="$1"
	local repo_slug="$2"

	local issue_labels
	issue_labels=$(gh issue view "$issue_number" --repo "$repo_slug" \
		--json labels --jq '[.labels[].name] | join(",")' 2>/dev/null) || issue_labels=""
	# Skip if consolidation was already done (label removed = consolidated)
	if [[ ",$issue_labels," == *",consolidated,"* ]]; then
		return 1
	fi
	# t1982: Skip if an open consolidation-task child already references this
	# parent. Prevents double-dispatch during the race window between the
	# child being created and _reevaluate_consolidation_labels re-checking.
	if _consolidation_child_exists "$issue_number" "$repo_slug"; then
		return 1
	fi
	# If already labeled, re-evaluate with the current (tighter) filter.
	# If the issue no longer triggers, auto-clear the label so it becomes
	# dispatchable without manual intervention. This handles the case where
	# a filter improvement makes previously-flagged issues pass.
	local was_already_labeled=false
	if [[ ",$issue_labels," == *",needs-consolidation,"* ]]; then
		was_already_labeled=true
	fi

	# t2161: Defence-in-depth — if an open PR already resolves this parent
	# (closing keyword + #N), the work is in flight. Skip consolidation
	# regardless of substantive-comment count. This catches the cascade
	# vector where version drift on a contributor runner re-introduces a
	# stale filter (root cause of GH#19448 → #19469 → #19471). Auto-clear
	# any pre-existing needs-consolidation label so the issue can close
	# cleanly when the PR merges.
	if _consolidation_resolving_pr_exists "$issue_number" "$repo_slug"; then
		[[ "$was_already_labeled" == "true" ]] &&
			_clear_needs_consolidation_label "$issue_number" "$repo_slug" \
				"in-flight resolving PR exists (t2161)"
		return 1
	fi

	# Count substantive comments (>MIN_CHARS, not from bots or dispatch machinery).
	# Only human-authored scope-changing comments should count. Operational
	# comments (dispatch claims, kill notices, crash reports, stale recovery,
	# triage reviews, provenance metadata) are noise — workers generate dozens
	# of these on issues that fail repeatedly, falsely triggering consolidation.
	local comments_json
	comments_json=$(gh api "repos/${repo_slug}/issues/${issue_number}/comments" \
		--paginate --jq '.' 2>/dev/null) || comments_json="[]"

	local substantive_count=0
	# Defaults are set at module level (: "${VAR:=value}" block above).
	# Bare $VAR reference is safe; the module-level block guarantees non-empty.
	local min_chars="$ISSUE_CONSOLIDATION_COMMENT_MIN_CHARS"
	substantive_count=$(printf '%s' "$comments_json" | jq --argjson min "$min_chars" '
		# Combine all operational-noise patterns into a single regex for efficiency
		# (1 test() invocation per comment instead of 15).
		#
		# t2144: Added ^<!-- WORKER_SUPERSEDED and ^<!-- stale-recovery-tick
		# patterns. Real recovery comment bodies start with these HTML comment
		# markers, then contain "**Stale assignment recovered**" later in the
		# body. The ^(\\*\\*)?Stale... anchor was therefore a no-op — 528-char
		# recovery comments passed the filter, and two of them on any stuck
		# issue falsely tripped the ISSUE_CONSOLIDATION_COMMENT_THRESHOLD=2 gate.
		(
			"DISPATCH_CLAIM nonce="
			+ "|^(<!-- ops:start[^>]*-->\\s*)?Dispatching worker"
			+ "|^<!-- (nmr-hold|aidevops-signed|ops:start|provenance:start)"
			+ "|^<!-- WORKER_SUPERSEDED"
			+ "|^<!-- stale-recovery-tick"
			+ "|CLAIM_RELEASED reason="
			+ "|^(Worker failed:|## Worker Watchdog Kill)"
			+ "|^(\\*\\*)?Stale assignment recovered"
			+ "|^## (Triage Review|Completion Summary|Large File Simplification Gate|Issue Consolidation Needed|Issue Consolidation Dispatched|Additional Review Feedback|Cascade Tier Escalation)"
			+ "|^This quality-debt issue was auto-generated by"
			+ "|<!-- MERGE_SUMMARY -->"
			+ "|^Closing:"
			+ "|^Worker failed: orphan worktree"
			+ "|sudo aidevops approve"
			+ "|^_Automated by"
		) as $patterns |
		[.[] | select(
			(.body | length) >= $min
			and .user.type != "Bot"
			and (.body | test($patterns) | not)
		)] | length
	' 2>/dev/null) || substantive_count=0

	if [[ "$substantive_count" -ge "$ISSUE_CONSOLIDATION_COMMENT_THRESHOLD" ]]; then
		return 0
	fi

	# Auto-clear: if the issue was previously labeled but no longer triggers
	# (e.g., filter improvement excluded operational comments that were false
	# positives), remove the label so it becomes dispatchable immediately.
	[[ "$was_already_labeled" == "true" ]] &&
		_clear_needs_consolidation_label "$issue_number" "$repo_slug" \
			"substantive_count=${substantive_count} below threshold=${ISSUE_CONSOLIDATION_COMMENT_THRESHOLD}"
	return 1
}

#######################################
# Re-evaluate all needs-consolidation labeled issues across pulse repos.
# Issues filtered out by list_dispatchable_issue_candidates_json (needs-*
# exclusion) never reach dispatch_with_dedup, so the auto-clear logic in
# _issue_needs_consolidation can't fire. This pass runs them through the
# current filter and removes the label if they no longer trigger.
# Lightweight: one gh issue list per repo + one _issue_needs_consolidation
# call per labeled issue. Runs every cycle before the early fill floor.
#######################################
_reevaluate_consolidation_labels() {
	local repos_json="$REPOS_JSON"
	[[ -f "$repos_json" ]] || return 0

	local total_cleared=0
	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue
		local issues_json
		issues_json=$(gh issue list --repo "$slug" --state open \
			--label "needs-consolidation" \
			--json number --limit 50 2>/dev/null) || issues_json="[]"

		while IFS= read -r num; do
			[[ "$num" =~ ^[0-9]+$ ]] || continue
			# _issue_needs_consolidation returns 1 (no consolidation needed)
			# AND auto-clears the label when was_already_labeled=true
			if ! _issue_needs_consolidation "$num" "$slug"; then
				total_cleared=$((total_cleared + 1))
			fi
		done < <(printf '%s' "$issues_json" | jq -r '.[]?.number // ""')
	done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | .slug' "$repos_json" 2>/dev/null)

	if [[ "$total_cleared" -gt 0 ]]; then
		echo "[pulse-wrapper] Consolidation re-evaluation: cleared ${total_cleared} stale needs-consolidation label(s)" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# Post a "Large File Simplification Gate — CLEARED" follow-up comment
# on an issue whose `needs-simplification` label was just removed. This
# annotates the prior "Held from dispatch" comment as superseded so
# readers (workers, supervisors, humans) don't act on stale state.
#
# Idempotent: uses _gh_idempotent_comment with a per-issue marker so it
# only posts once per clearing event even if the re-eval loop visits the
# same issue across multiple cycles.
#
# t2042: addresses the misleading-comment failure mode where #18418
# carried a "Held from dispatch" comment from a pre-t2024 gate
# evaluation while dispatch was already proceeding under the
# scoped-range bypass.
#
# Arguments:
#   $1 - issue_number
#   $2 - repo_slug
# Returns: 0 always (best-effort, never blocks)
#######################################
_post_simplification_gate_cleared_comment() {
	local issue_number="$1"
	local repo_slug="$2"

	[[ "$issue_number" =~ ^[0-9]+$ ]] || return 0
	[[ -n "$repo_slug" ]] || return 0

	local _scoped_threshold="${SCOPED_RANGE_THRESHOLD:-300}"
	local _large_threshold="${LARGE_FILE_LINE_THRESHOLD:-2000}"
	local _marker="<!-- simplification-gate-cleared:${issue_number} -->"
	local _body="${_marker}
## Large File Simplification Gate — CLEARED

The previous \"Held from dispatch\" comment on this issue no longer
applies. On re-evaluation, the cited file references either fall within
the scoped-range bypass (≤ ${_scoped_threshold} lines per range) or the
target file has been simplified below ${_large_threshold} lines.

The \`needs-simplification\` label has been removed and the issue is
open for dispatch.

_Automated by \`_post_simplification_gate_cleared_comment()\` in pulse-triage.sh (t2042)_"

	_gh_idempotent_comment "$issue_number" "$repo_slug" \
		"$_marker" "$_body" || true
	return 0
}

#######################################
# t2170 Fix E (secondary): Check if ALL continuation citations in the
# large-file gate sticky comment are stale. Called when
# _issue_targets_large_files returned 0 (file still targeted) to detect
# deadlocked issues where phantom continuations prevent fresh gate
# re-evaluation.
#
# A continuation citation is stale when:
#   - The cited issue is CLOSED, AND one of:
#     (a) it carries `simplification-incomplete` (Fix D, t2169) — file
#         never simplified; short-circuits the wc -l check.
#     (b) _large_file_gate_verify_prior_reduced_size confirms file is
#         still over threshold.
#   - If the cited issue is OPEN → valid (work in progress), preserve.
#   - If the issue or its path is unresolvable → conservative: preserve.
#
# When ALL citations are stale the label is removed so the next dispatch
# cycle re-fires the gate fresh (which, post-Fix-A/B, files a new debt
# issue instead of re-citing the phantom).
#
# Arguments:
#   $1 - issue_number
#   $2 - repo_slug
#   $3 - repo_path
# Returns: 0 (cleared label), 1 (preserved label)
#######################################
_reevaluate_stale_continuations() {
	local issue_number="$1"
	local repo_slug="$2"
	local repo_path="$3"

	# Fetch gate sticky comment. map+.[0] preserves the full multi-line body
	# (.[]+head-1 would truncate to the heading line, losing the issue refs).
	local gate_comment
	gate_comment=$(gh issue view "$issue_number" --repo "$repo_slug" \
		--comments --json comments \
		--jq '.comments | map(select(.body | contains("## Large File Simplification Gate"))) | .[0].body // empty' \
		2>/dev/null) || gate_comment=""
	[[ -n "$gate_comment" ]] || return 1

	# Extract only the "recently-closed — continuation" issue numbers; open
	# "existing"/"new" entries don't cause the deadlock this fix targets.
	local continuation_nums
	continuation_nums=$(printf '%s' "$gate_comment" |
		grep -oE '#[0-9]+ \(recently-closed' |
		grep -oE '[0-9]+') || continuation_nums=""
	[[ -n "$continuation_nums" ]] || return 1

	local all_stale="true"
	local cont_num
	while IFS= read -r cont_num; do
		[[ "$cont_num" =~ ^[0-9]+$ ]] || continue

		local cont_info cont_state cont_labels
		cont_info=$(gh issue view "$cont_num" --repo "$repo_slug" \
			--json state,labels,title 2>/dev/null) || cont_info=""
		if [[ -z "$cont_info" ]]; then
			all_stale="false"
			break # Unresolvable → conservative
		fi

		cont_state=$(printf '%s' "$cont_info" | jq -r '.state // "OPEN"' 2>/dev/null)
		cont_state_upper=$(printf '%s' "$cont_state" | tr '[:lower:]' '[:upper:]')
		if [[ "$cont_state_upper" != "CLOSED" ]]; then
			all_stale="false"
			break # Open → work in progress
		fi

		# Closed — short-circuit via simplification-incomplete (Fix D, t2169)
		# or verify via file-size check.
		cont_labels=$(printf '%s' "$cont_info" | jq -r '[.labels[].name] | join(",")' 2>/dev/null) || cont_labels=""
		if [[ ",$cont_labels," == *",simplification-incomplete,"* ]]; then
			continue # definite stale, no wc -l needed
		fi

		# Parse path from title: "file-size-debt: <path> exceeds N lines"
		# Also handles legacy "simplification-debt: <path> exceeds N lines" titles
		# for backward compat during the label migration period.
		local cont_title cont_file_path
		cont_title=$(printf '%s' "$cont_info" | jq -r '.title // ""' 2>/dev/null) || cont_title=""
		cont_file_path=$(printf '%s' "$cont_title" |
			sed 's/^file-size-debt: //;s/^simplification-debt: //;s/ exceeds [0-9]* lines$//' 2>/dev/null) || cont_file_path=""
		if [[ -z "$cont_file_path" || "$cont_file_path" == "$cont_title" ]]; then
			all_stale="false"
			break # Path unresolvable → conservative
		fi

		# Guard: function is in pulse-dispatch-large-file-gate.sh (sourced first)
		if ! declare -F _large_file_gate_verify_prior_reduced_size >/dev/null 2>&1; then
			all_stale="false"
			break # Function unavailable → conservative
		fi

		# Returns 0 = file under threshold (valid), 1 = still over (stale)
		if _large_file_gate_verify_prior_reduced_size \
			"$cont_num" "$cont_file_path" "$repo_path"; then
			all_stale="false"
			break # Prior work was effective → valid citation
		fi
	done < <(printf '%s\n' "$continuation_nums")

	if [[ "$all_stale" == "true" ]]; then
		gh issue edit "$issue_number" --repo "$repo_slug" \
			--remove-label "needs-simplification" >/dev/null 2>&1 || true
		echo "[pulse-triage] Cleared stale needs-simplification on #${issue_number} (all cited continuations phantom; next dispatch will re-evaluate the gate)" >>"$LOGFILE"
		return 0
	fi
	return 1
}

#######################################
# Re-evaluate needs-simplification labeled issues across pulse repos.
# Same pattern as _reevaluate_consolidation_labels: issues filtered out
# by the needs-* exclusion never reach dispatch_with_dedup, so the
# auto-clear at the end of _issue_targets_large_files can't fire.
# This pass re-evaluates them and clears the label when the file is
# now excluded (lockfile, JSON config) or below threshold.
#
# t2170 Fix E (secondary): also runs _reevaluate_stale_continuations when
# _issue_targets_large_files returns 0 (file still targeted). This covers
# the deadlock where phantom continuation citations block the gate from
# re-firing and creating a fresh (accurate) debt issue.
#######################################
_reevaluate_simplification_labels() {
	local repos_json="$REPOS_JSON"
	[[ -f "$repos_json" ]] || return 0

	local total_cleared=0
	while IFS='|' read -r slug rpath; do
		[[ -n "$slug" && -n "$rpath" ]] || continue
		local issues_json
		issues_json=$(gh issue list --repo "$slug" --state open \
			--label "needs-simplification" \
			--json number --limit 50 2>/dev/null) || issues_json="[]"

		while IFS= read -r num; do
			[[ "$num" =~ ^[0-9]+$ ]] || continue
			local body
			body=$(gh issue view "$num" --repo "$slug" \
				--json body --jq '.body // ""' 2>/dev/null) || body=""
			# _issue_targets_large_files returns 1 (no large files) AND
			# auto-clears the label when was_already_labeled.
			# t1998: pass force_recheck=true to bypass the
			# skip-if-already-labeled short-circuit at pulse-dispatch-core.sh:592.
			# Without this flag, the re-eval loop never sees a cleared case
			# because the function returns 0 immediately on any already-labeled
			# issue, keeping stale needs-simplification labels forever.
			if ! _issue_targets_large_files "$num" "$slug" "$body" "$rpath" "true"; then
				total_cleared=$((total_cleared + 1))
				# t2042: post follow-up "CLEARED" comment so the original
				# "Held from dispatch" comment doesn't mislead readers.
				_post_simplification_gate_cleared_comment "$num" "$slug"
			else
				# t2170 Fix E (secondary): file still targets large files but
				# check if ALL cited continuation issues are stale/phantom.
				# Clears the label so the next dispatch cycle re-evaluates
				# the gate fresh — breaking the deadlock where a phantom
				# continuation blocks new accurate debt issue creation.
				if _reevaluate_stale_continuations "$num" "$slug" "$rpath"; then
					total_cleared=$((total_cleared + 1))
				fi
			fi
		done < <(printf '%s' "$issues_json" | jq -r '.[]?.number // ""')
	done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "" and .path != "") | "\(.slug)|\(.path)"' "$repos_json" 2>/dev/null)

	if [[ "$total_cleared" -gt 0 ]]; then
		echo "[pulse-wrapper] Simplification re-evaluation: cleared ${total_cleared} stale needs-simplification label(s)" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# t1982/t2144/t2151: Check whether a consolidation-task child issue currently
# "owns" this parent. Used by both _issue_needs_consolidation (as a
# pre-filter) and _dispatch_issue_consolidation (as an idempotency guard)
# so that repeat calls on the same parent do not create duplicate children.
#
# A child "owns" the parent if ANY of:
#   (a) a consolidation-task child is currently open, OR
#   (b) a consolidation-task child closed within the grace window
#       (CONSOLIDATION_RECENT_CLOSE_GRACE_MIN minutes, default 30), OR
#   (c) (t2151) the parent carries the `consolidation-in-progress` label —
#       another pulse runner is mid-way through creating a child right now.
#
# (a) and (b) cover single-runner cascades (t1982 / t2144).
# (c) covers the cross-runner race window between "about to create child"
# and "child exists on GitHub". See `_consolidation_lock_acquire` for the
# lock protocol.
#
# The grace window exists because closing the consolidation-task child
# and applying the `consolidated` label to the parent are separate steps —
# the worker closes the child first, then updates the parent. Between
# those two API calls the state is {child: closed, parent: still needs-
# consolidation, no open child}. `_backfill_stale_consolidation_labels`
# previously saw this as "no child, dispatch a new one" and re-fired,
# cascading indefinitely (observed: #19321 → #19341 + #19367 cascade on
# 2026-04-16 across two pulse runners). The grace window collapses that
# race to a single cycle.
#
# Uses GitHub's `in:body` search over the consolidation-task label scope.
# The child body always contains the literal token "Consolidation target: #NNN"
# (see _compose_consolidation_child_body) which is the searchable anchor.
#
# Args: $1=parent_num $2=repo_slug [$3=grace_minutes_override]
# Returns: 0 if an open-or-recently-closed child exists OR lock label is
#          present, 1 otherwise.
#######################################
_consolidation_child_exists() {
	local parent_num="$1"
	local repo_slug="$2"
	local grace_minutes="${3:-${CONSOLIDATION_RECENT_CLOSE_GRACE_MIN:-30}}"

	[[ -n "$parent_num" && -n "$repo_slug" ]] || return 1

	# Fast path: any open child immediately owns the parent.
	local open_count
	open_count=$(gh issue list --repo "$repo_slug" --state open \
		--label "consolidation-task" \
		--search "in:body \"Consolidation target: #${parent_num}\"" \
		--json number --jq 'length' --limit 5 2>/dev/null) || open_count=0
	[[ "$open_count" =~ ^[0-9]+$ ]] || open_count=0
	if [[ "$open_count" -gt 0 ]]; then
		return 0
	fi

	# t2151: lock label is a third blocking condition. A competing runner
	# that has acquired (or is acquiring) the lock owns the parent for the
	# duration of its critical section. Cheap — one label-read, no search.
	if _consolidation_lock_label_present "$parent_num" "$repo_slug"; then
		return 0
	fi

	# No open child — check for a recently-closed one within the grace
	# window. grace_minutes=0 disables the window (test hook).
	[[ "$grace_minutes" =~ ^[0-9]+$ ]] || grace_minutes=30
	if [[ "$grace_minutes" -eq 0 ]]; then
		return 1
	fi

	# Prefer GNU date -d (Linux, coreutils); fall back to BSD date -v (macOS).
	local cutoff_iso=""
	cutoff_iso=$(date -u -d "${grace_minutes} minutes ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null) || cutoff_iso=""
	if [[ -z "$cutoff_iso" ]]; then
		cutoff_iso=$(date -u -v-"${grace_minutes}"M +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null) || cutoff_iso=""
	fi
	# If both date variants failed (highly unusual), fall back to open-only
	# behaviour. This preserves pre-t2144 semantics rather than risking
	# false negatives from a broken cutoff.
	[[ -n "$cutoff_iso" ]] || return 1

	local recent_closed_count
	recent_closed_count=$(gh issue list --repo "$repo_slug" --state closed \
		--label "consolidation-task" \
		--search "in:body \"Consolidation target: #${parent_num}\" closed:>${cutoff_iso}" \
		--json number --jq 'length' --limit 5 2>/dev/null) || recent_closed_count=0
	[[ "$recent_closed_count" =~ ^[0-9]+$ ]] || recent_closed_count=0
	[[ "$recent_closed_count" -gt 0 ]]
}

#######################################
# t2161: Check whether an open PR with a GitHub-native closing keyword
# referencing this parent issue is currently in-flight. Used as a safety
# net by `_issue_needs_consolidation` and `_dispatch_issue_consolidation`
# to prevent the cascade observed in GH#19448 → GH#19469 → GH#19471, where
# version drift on a contributor runner caused a stale filter to falsely
# trigger consolidation while a fix PR was already mergeable.
#
# Why this is needed AT ALL given t2144's filter fix:
#   The substantive-comment filter is the right primary defence (it solves
#   the cause: noise comments). This helper is a defence-in-depth safety
#   net that holds even when:
#     (a) a contributor runner is running pre-t2144 code,
#     (b) a future filter regression slips through,
#     (c) a new operational comment shape ships and drifts past the regex.
#   In all three cases, the existence of an in-flight PR resolving the
#   parent is a strong, runtime-checkable "the work is in progress, do
#   not file a planning task on top of it" signal.
#
# Why "in-flight PR" is a stronger signal than "open PR":
#   GitHub only auto-closes the issue when the PR MERGES, so an open PR
#   with a closing keyword has not yet resolved the issue — but the work
#   is committed, reviewable, and a consolidation child filed now would
#   become noise the moment the PR merges (the issue closes within
#   seconds of merge). Asymmetric cost: skipping consolidation when there
#   is an in-flight fix is cheap and reversible (the next pulse cycle
#   fires if the PR closes without merging); filing a duplicate child
#   issue burns a worker session and pollutes the issue thread.
#
# Closing-keyword regex sourced from `_extract_linked_issue` in
# pulse-merge.sh:1173 — matches GitHub's full close keyword list:
# close/closes/closed, fix/fixes/fixed, resolve/resolves/resolved
# (case-insensitive). Bare `#NNN` references and `For #NNN` / `Ref #NNN`
# references do NOT match — those are intentionally non-closing.
#
# Args: $1=parent_num $2=repo_slug
# Returns: 0 if an open PR with a closing keyword referencing the parent
#          exists, 1 otherwise (including network/parse errors — fail open
#          so a misbehaving search never blocks legitimate consolidation).
#######################################
_consolidation_resolving_pr_exists() {
	local parent_num="$1"
	local repo_slug="$2"

	[[ -n "$parent_num" && -n "$repo_slug" ]] || return 1

	# Fast prefilter: GitHub search for open PRs that mention the parent
	# anywhere in body. Cheap (one search hit, capped at 10 results) and
	# scopes the regex match below to the small candidate set.
	local prs_json
	prs_json=$(gh pr list --repo "$repo_slug" --state open \
		--search "in:body #${parent_num}" \
		--json number,body --limit 10 2>/dev/null) || prs_json="[]"
	[[ -n "$prs_json" ]] || prs_json="[]"

	# Filter for GitHub-native closing keyword + #N (case-insensitive).
	# Word boundary on the trailing # is enforced via the look-ahead
	# `[^0-9]` (or end of string) so #${parent_num} does not match
	# #${parent_num}1 / #${parent_num}99 etc.
	local match_count
	match_count=$(printf '%s' "$prs_json" | jq --arg n "$parent_num" '
		[.[] | select(
			(.body // "")
			| test("(?i)\\b(close[ds]?|fix(es|ed)?|resolve[ds]?)[ \\t]+#" + $n + "\\b")
		)] | length
	' 2>/dev/null) || match_count=0
	[[ "$match_count" =~ ^[0-9]+$ ]] || match_count=0
	if [[ "$match_count" -gt 0 ]]; then
		return 0
	fi
	return 1
}

#######################################
# t1982: Fetch and filter substantive comments on an issue using the same
# predicate as the substantive_count in _issue_needs_consolidation. Returns
# a JSON array of {login, created_at, body} objects on stdout.
#
# Kept in its own helper so the dispatch path can reuse the filter without
# re-implementing it, and so future filter tweaks live in one place.
#######################################
_consolidation_substantive_comments() {
	local issue_number="$1"
	local repo_slug="$2"

	local comments_json
	comments_json=$(gh api "repos/${repo_slug}/issues/${issue_number}/comments" \
		--paginate --jq '.' 2>/dev/null) || comments_json="[]"

	local min_chars="$ISSUE_CONSOLIDATION_COMMENT_MIN_CHARS"

	# t2144: Added ^<!-- WORKER_SUPERSEDED and ^<!-- stale-recovery-tick
	# patterns here too — this helper is used by the dispatch path to compose
	# the child issue body, so it must stay in lockstep with the predicate in
	# _issue_needs_consolidation above. Divergence between the two filters
	# would mean the child ISSUE shows WORKER_SUPERSEDED comments as
	# "substantive" even though they can no longer trigger dispatch.
	printf '%s' "$comments_json" | jq --argjson min "$min_chars" '
		[.[] | select(
			(.body | length) >= $min
			and (.user.type != "Bot")
			and (.body | test("DISPATCH_CLAIM nonce=") | not)
			and (.body | test("^(<!-- ops:start[^>]*-->\\s*)?Dispatching worker") | not)
			and (.body | test("^<!-- (nmr-hold|aidevops-signed|ops:start|provenance:start)") | not)
			and (.body | test("^<!-- WORKER_SUPERSEDED") | not)
			and (.body | test("^<!-- stale-recovery-tick") | not)
			and (.body | test("CLAIM_RELEASED reason=") | not)
			and (.body | test("^(Worker failed:|## Worker Watchdog Kill)") | not)
			and (.body | test("^(\\*\\*)?Stale assignment recovered") | not)
			and (.body | test("^## (Triage Review|Completion Summary|Large File Simplification Gate|Issue Consolidation Needed|Issue Consolidation Dispatched|Additional Review Feedback|Cascade Tier Escalation)") | not)
			and (.body | test("^This quality-debt issue was auto-generated by") | not)
			and (.body | test("<!-- MERGE_SUMMARY -->") | not)
			and (.body | test("^Closing:") | not)
			and (.body | test("^Worker failed: orphan worktree") | not)
			and (.body | test("sudo aidevops approve") | not)
			and (.body | test("^_Automated by") | not)
		) | {login: .user.login, created_at: .created_at, body: .body}]
	' 2>/dev/null || printf '[]'
	return 0
}

#######################################
# t1982: Format substantive comments JSON into a readable Markdown section.
# Returns formatted text to stdout. Called by _compose_consolidation_child_body.
#
# Args: $1=substantive_json
#######################################
_format_consolidation_comments_section() {
	local substantive_json="$1"
	local result
	result=$(printf '%s' "$substantive_json" | jq -r '
		if (. | length) == 0 then
			"_No substantive comments captured — the filter excluded everything. If this seems wrong, inspect the filter in _consolidation_substantive_comments._"
		else
			to_entries | map(
				"### Comment " + ((.key + 1) | tostring) + " — @" + .value.login + " at " + .value.created_at +
				"\n\n" + .value.body + "\n"
			) | join("\n---\n\n")
		end
	' 2>/dev/null) || result="_Comment fetch failed._"
	printf '%s' "$result"
	return 0
}

#######################################
# t1982: Compose the "What to do" instructions and "Constraints" sections
# for the consolidation-task child body. Called by _compose_consolidation_child_body.
#
# Args: $1=parent_num $2=repo_slug $3=authors_line
#######################################
_compose_consolidation_worker_instructions() {
	local parent_num="$1"
	local repo_slug="$2"
	local authors_line="$3"

	cat <<EOF
## What to do

1. **Read the parent body and substantive comments inlined below.** Identify:
   - The original problem statement
   - Scope modifications added by commenters (additions, corrections, clarifications)
   - Resolved questions, rejected ideas, or superseded decisions
   - The final agreed-upon approach

2. **Compose a single coherent issue body** in the aidevops brief format (see \`templates/brief-template.md\`):
   - \`## What\` — the deliverable
   - \`## Why\` — the problem and rationale
   - \`## How\` — approach with explicit file paths and line references
   - \`## Acceptance Criteria\` — testable checkboxes
   - \`## Context & Decisions\` — which commenter contributed which insight (attribution matters)
   - \`## Contributors\` — a cc line @-mentioning every author from the list below

   Start the merged body with: \`_Supersedes #${parent_num} — this issue is the consolidated spec._\`

3. **File the new consolidated issue:**

\`\`\`bash
gh issue create --repo "${repo_slug}" \\
  --title "consolidated: <concise description derived from the merged spec>" \\
  --label "consolidated,origin:worker,<copy relevant labels from parent, excluding needs-consolidation, consolidation-task, and origin:interactive>" \\
  --body "<merged body from step 2>"
\`\`\`

**Note (GH#18670):** \`origin:worker\` is mandatory on this label list — consolidated issues are pulse-generated artifacts, not interactive maintainer work. Without it, the issue is born \`origin:interactive\` (raw \`gh issue create\` has no origin auto-detection), which triggers the GH#18352 dispatch-dedup block and drains the queue.

   Capture the new issue number as \$NEW_NUM.

4. **Close the parent #${parent_num}:**

\`\`\`bash
gh issue comment ${parent_num} --repo "${repo_slug}" \\
  --body "Superseded by #\$NEW_NUM. The merged spec is inlined on the new issue — continue discussion there."
gh issue edit ${parent_num} --repo "${repo_slug}" \\
  --add-label "consolidated" --remove-label "needs-consolidation"
gh issue close ${parent_num} --repo "${repo_slug}" --reason "not planned"
\`\`\`

5. **Close this consolidation-task issue** with a summary comment:

\`\`\`bash
gh issue comment \$THIS_ISSUE --repo "${repo_slug}" \\
  --body "Consolidation complete. Parent: #${parent_num} → New: #\$NEW_NUM. Contributors @-mentioned: ${authors_line}."
gh issue close \$THIS_ISSUE --repo "${repo_slug}" --reason "completed"
\`\`\`

## Constraints

- **Do NOT read #${parent_num}** — it is inlined below. Reading it wastes the token budget.
- **Preserve all substantive content.** Merging is not summarising. If a comment adds a constraint, that constraint must appear in the merged body.
- **Preserve author attribution** for specific contributions: "per @user1: …".
- **No PR is required.** This is an operational task. The completion signal is the new issue number + parent closure + self-close.
- **Contributors to @-mention** on the new issue: ${authors_line}
EOF
}

#######################################
# t1982: Compose a self-contained consolidation-task child issue body.
#
# The worker reading this body must NOT need to read the parent — all
# required content is inlined here. Includes:
#   - Consolidation target marker (for dedup lookup)
#   - Explicit worker instructions (gh commands)
#   - Parent body verbatim
#   - Substantive comments verbatim (author + timestamp headers)
#   - Contributors cc line (@mentions)
#
# Args: parent_num repo_slug parent_title parent_body substantive_json authors_csv parent_labels
#######################################
_compose_consolidation_child_body() {
	local parent_num="$1"
	local repo_slug="$2"
	local parent_title="$3"
	local parent_body="$4"
	local substantive_json="$5"
	local authors_csv="$6"
	local parent_labels="$7"

	local comments_section
	comments_section=$(_format_consolidation_comments_section "$substantive_json")

	local authors_line="${authors_csv:-_no substantive authors detected_}"
	local parent_body_section="${parent_body:-_(parent body was empty)_}"

	local instructions_block
	instructions_block=$(_compose_consolidation_worker_instructions \
		"$parent_num" "$repo_slug" "$authors_line")

	cat <<EOF
## Consolidation target: #${parent_num}

**Parent issue:** #${parent_num} in \`${repo_slug}\`
**Parent title:** ${parent_title}
**Parent labels:** \`${parent_labels}\`

> You do **NOT** need to read #${parent_num}. Everything required is inlined below.
> Reading the parent wastes the token budget and is explicitly disallowed for this task.

${instructions_block}

## Parent body (verbatim)

${parent_body_section}

## Substantive comments (verbatim, in chronological order)

${comments_section}

---

_Self-contained dispatch packet generated by \`_dispatch_issue_consolidation()\` in \`pulse-triage.sh\` (t1982). Everything above is sufficient — do not read #${parent_num}._
EOF
}

#######################################
# t1982: Ensure the three GitHub labels required for the consolidation
# workflow exist on the given repo. Idempotent (uses --force).
# Called by _dispatch_issue_consolidation.
#
# Args: $1=repo_slug
#######################################
_ensure_consolidation_labels() {
	local repo_slug="$1"
	gh label create "needs-consolidation" \
		--repo "$repo_slug" \
		--description "Issue held from dispatch pending comment consolidation" \
		--color "FBCA04" --force 2>/dev/null || true
	gh label create "consolidation-task" \
		--repo "$repo_slug" \
		--description "Operational task: merge parent issue body + comments into a consolidated child issue" \
		--color "C5DEF5" --force 2>/dev/null || true
	gh label create "consolidated" \
		--repo "$repo_slug" \
		--description "Issue superseded by a consolidated child" \
		--color "0E8A16" --force 2>/dev/null || true
	# t2151: cross-runner advisory lock for consolidation dispatch. Applied by
	# `_consolidation_lock_acquire` before child issue creation; treated as an
	# active-claim signal by `dispatch-dedup-helper.sh is-assigned` so unrelated
	# dispatch paths can't sneak past during the write window.
	gh label create "consolidation-in-progress" \
		--repo "$repo_slug" \
		--description "Another runner is creating a consolidation child issue (cross-runner advisory lock)" \
		--color "CFD3D7" --force 2>/dev/null || true
	return 0
}

#######################################
# t2151: Cross-runner advisory lock — marker comment protocol.
#
# Two pulse runners on different hosts can hit the same parent issue within
# the same consolidation window. Neither sees the other's in-flight gh writes
# directly, so both pass local `_consolidation_child_exists` and both create
# a child. Production evidence: parent #19321 → #19341 (marcusquinn) +
# #19367 (alex-solovyev, 55 min later).
#
# Protocol:
#   1. acquire: apply `consolidation-in-progress` label, post a signed
#      marker comment (HTML-comment prefix + runner login + ISO timestamp),
#      wait briefly for any competitor's marker to flush, re-read comments.
#   2. tiebreak: if multiple markers are present, lexicographic actor-login
#      comparison picks the single winner. Last-writer-loses when logins are
#      identical is impossible here (GitHub logins are unique), but if the
#      same runner somehow posts twice, the older comment wins.
#   3. release: remove the label and delete our marker comment. Release
#      happens after successful child creation OR on any failure path.
#
# Why a comment marker plus a label, not just the label?
#   The label alone is not enough for tiebreaking: `gh issue edit --add-label`
#   is idempotent — after both runners apply the label, we cannot tell from
#   the label alone who "got there first". A comment with a unique marker
#   body and a runner-specific signature gives us a deterministic tiebreaker
#   that works under real concurrent-API-call conditions, and crucially
#   leaves an audit trail of every lock attempt.
#
# Why not rely on `gh issue edit` being atomic?
#   `--add-label X` is atomic at the API-call surface, but two runners calling
#   it near-simultaneously both observe their own call as "the label didn't
#   exist, now it does". GitHub doesn't return a "label was already present"
#   signal on the REST API. Hence the marker-comment protocol.
#######################################

# t2151: generate the marker comment text for a lock acquisition.
# Format: `<!-- consolidation-lock:runner=LOGIN ts=ISO8601 -->` on a single line.
# The single-line HTML-comment prefix is the stable anchor that filter regexes
# and grep-style tests can match without ambiguity.
_consolidation_lock_marker_body() {
	local self_login="$1"
	local iso_ts="$2"
	printf '<!-- consolidation-lock:runner=%s ts=%s -->\n_Cross-runner advisory lock acquired for consolidation dispatch (t2151). This comment will be removed when the lock is released._' \
		"$self_login" "$iso_ts"
	return 0
}

# t2151: fetch all lock marker comments on the parent. Returns a JSON array
# of {id, login, created_at} objects to stdout, sorted by created_at ascending.
# Empty array on API failure.
_consolidation_lock_markers() {
	local parent_num="$1"
	local repo_slug="$2"
	gh api "repos/${repo_slug}/issues/${parent_num}/comments" --paginate \
		--jq '[.[] | select(.body | test("^<!-- consolidation-lock:runner=[A-Za-z0-9_-]+ ts="))
			| {id: .id, body: .body, created_at: .created_at,
				runner: (.body | capture("^<!-- consolidation-lock:runner=(?<r>[A-Za-z0-9_-]+)") | .r)}]
			| sort_by(.created_at)' 2>/dev/null || printf '[]'
	return 0
}

# t2151: determine self login — the current runner's GitHub login. Workers
# and pulse runners authenticate via `gh auth login`; the login returned by
# `gh api user` is the same one that appears in comment.user.login. Returns
# empty on failure; callers MUST treat empty as "cannot acquire lock" and
# skip dispatch rather than proceed blindly.
_consolidation_lock_self_login() {
	# Prefer an explicit override for tests.
	if [[ -n "${CONSOLIDATION_LOCK_SELF_LOGIN_OVERRIDE:-}" ]]; then
		printf '%s' "$CONSOLIDATION_LOCK_SELF_LOGIN_OVERRIDE"
		return 0
	fi
	gh api user --jq '.login' 2>/dev/null || true
	return 0
}

# t2151: determine if parent currently carries the lock label.
# Args: $1=parent_num $2=repo_slug
# Returns: 0 if label is present, 1 otherwise.
_consolidation_lock_label_present() {
	local parent_num="$1"
	local repo_slug="$2"
	local labels_csv
	labels_csv=$(gh issue view "$parent_num" --repo "$repo_slug" \
		--json labels --jq '[.labels[].name] | join(",")' 2>/dev/null) || labels_csv=""
	[[ ",${labels_csv}," == *",consolidation-in-progress,"* ]]
}

# t2151: release the lock — delete our marker comment(s) and remove the label
# if no other runner's marker is present. Safe to call even if acquire failed
# (idempotent). Never fails the caller — release best-effort.
#
# Args: $1=parent_num $2=repo_slug $3=self_login
_consolidation_lock_release() {
	local parent_num="$1"
	local repo_slug="$2"
	local self_login="$3"

	[[ -n "$parent_num" && -n "$repo_slug" ]] || return 0

	local markers_json
	markers_json=$(_consolidation_lock_markers "$parent_num" "$repo_slug")
	[[ -n "$markers_json" ]] || markers_json="[]"

	# Delete every marker that belongs to us.
	local self_marker_ids
	self_marker_ids=$(printf '%s' "$markers_json" |
		jq -r --arg me "$self_login" '.[] | select(.runner == $me) | .id' 2>/dev/null) || self_marker_ids=""
	local mid
	while IFS= read -r mid; do
		[[ -z "$mid" ]] && continue
		gh api -X DELETE "repos/${repo_slug}/issues/comments/${mid}" >/dev/null 2>&1 || true
	done <<<"$self_marker_ids"

	# If no other runner's marker remains, drop the lock label. Otherwise a
	# competing runner is still inside its own acquire/dispatch window — don't
	# clear the label out from under them.
	local other_count
	other_count=$(printf '%s' "$markers_json" |
		jq -r --arg me "$self_login" '[.[] | select(.runner != $me)] | length' 2>/dev/null) || other_count=0
	[[ "$other_count" =~ ^[0-9]+$ ]] || other_count=0
	if [[ "$other_count" -eq 0 ]]; then
		gh issue edit "$parent_num" --repo "$repo_slug" \
			--remove-label "consolidation-in-progress" >/dev/null 2>&1 || true
	fi
	return 0
}

# t2151: acquire the cross-runner lock. See protocol overview above.
#
# Args: $1=parent_num $2=repo_slug
# Returns:
#   0 — lock acquired, caller MUST proceed with child creation and
#       call _consolidation_lock_release after (success or failure).
#   1 — lock held by another runner or self_login unavailable; caller
#       MUST skip dispatch.
_consolidation_lock_acquire() {
	local parent_num="$1"
	local repo_slug="$2"

	[[ -n "$parent_num" && -n "$repo_slug" ]] || return 1

	local self_login
	self_login=$(_consolidation_lock_self_login)
	if [[ -z "$self_login" ]]; then
		# Cannot lock without knowing our identity — fail-closed: block
		# dispatch rather than create a duplicate. A transient `gh auth`
		# issue self-heals within one pulse cycle at zero cost.
		echo "[pulse-wrapper] Consolidation lock: gh api user failed for #${parent_num} in ${repo_slug} — skipping dispatch (fail-closed)" >>"$LOGFILE"
		return 1
	fi

	# Apply label first — cheapest signal for the fast-path competitor
	# who is about to call `_consolidation_child_exists`.
	gh issue edit "$parent_num" --repo "$repo_slug" \
		--add-label "consolidation-in-progress" >/dev/null 2>&1 || true

	# Post our marker. Embed the current ISO timestamp.
	local iso_ts
	iso_ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null) || iso_ts=""
	local marker_body
	marker_body=$(_consolidation_lock_marker_body "$self_login" "$iso_ts")
	gh_issue_comment "$parent_num" --repo "$repo_slug" \
		--body "$marker_body" >/dev/null 2>&1 || {
		# Comment post failed — can't tiebreak without our marker being
		# visible. Roll back by clearing the label and skip dispatch.
		gh issue edit "$parent_num" --repo "$repo_slug" \
			--remove-label "consolidation-in-progress" >/dev/null 2>&1 || true
		echo "[pulse-wrapper] Consolidation lock: marker comment post failed for #${parent_num} in ${repo_slug} — rolled back label, skipping dispatch" >>"$LOGFILE"
		return 1
	}

	# Give any concurrent competitor a short window to flush their marker.
	# `sleep 0` on tiebreak_wait=0 is a no-op — used by unit tests.
	local wait_sec="${CONSOLIDATION_LOCK_TIEBREAK_WAIT_SEC:-2}"
	[[ "$wait_sec" =~ ^[0-9]+$ ]] || wait_sec=2
	if [[ "$wait_sec" -gt 0 ]]; then
		sleep "$wait_sec" 2>/dev/null || true
	fi

	# Re-read markers and tiebreak.
	local markers_json
	markers_json=$(_consolidation_lock_markers "$parent_num" "$repo_slug")
	[[ -n "$markers_json" ]] || markers_json="[]"

	# Count distinct runners. If only one (us), we won trivially.
	local distinct_runners
	distinct_runners=$(printf '%s' "$markers_json" |
		jq -r '[.[].runner] | unique | length' 2>/dev/null) || distinct_runners=0
	[[ "$distinct_runners" =~ ^[0-9]+$ ]] || distinct_runners=0

	if [[ "$distinct_runners" -le 1 ]]; then
		# No competing runner — we own the lock.
		echo "[pulse-wrapper] Consolidation lock: acquired by ${self_login} on #${parent_num} in ${repo_slug}" >>"$LOGFILE"
		return 0
	fi

	# Tiebreak: lexicographically lowest login wins. Deterministic without
	# relying on clock skew between runners.
	local winner_login
	winner_login=$(printf '%s' "$markers_json" |
		jq -r '[.[].runner] | unique | sort | .[0]' 2>/dev/null) || winner_login=""

	if [[ "$winner_login" == "$self_login" ]]; then
		echo "[pulse-wrapper] Consolidation lock: won tiebreaker on #${parent_num} in ${repo_slug} (self=${self_login}, competitors=$(printf '%s' "$markers_json" | jq -r '[.[].runner] | unique | join(",")' 2>/dev/null))" >>"$LOGFILE"
		return 0
	fi

	# We lost. Release our marker but leave the label (winner still needs it).
	echo "[pulse-wrapper] Consolidation lock: lost tiebreaker on #${parent_num} in ${repo_slug} (self=${self_login}, winner=${winner_login}) — rolling back our marker" >>"$LOGFILE"
	local self_marker_ids
	self_marker_ids=$(printf '%s' "$markers_json" |
		jq -r --arg me "$self_login" '.[] | select(.runner == $me) | .id' 2>/dev/null) || self_marker_ids=""
	local mid
	while IFS= read -r mid; do
		[[ -z "$mid" ]] && continue
		gh api -X DELETE "repos/${repo_slug}/issues/comments/${mid}" >/dev/null 2>&1 || true
	done <<<"$self_marker_ids"
	return 1
}

#######################################
# t1982: File the consolidation child issue via a temp body file (avoids
# argv length limits on long parent bodies with many comments).
# Prints the child issue number to stdout on success, empty on failure.
# Called by _dispatch_issue_consolidation.
#
# Args: $1=repo_slug $2=issue_number $3=child_body
#######################################
_create_consolidation_child_issue() {
	local repo_slug="$1"
	local issue_number="$2"
	local child_body="$3"

	local body_file
	body_file=$(mktemp -t consolidation-child.XXXXXX) || {
		echo "[pulse-wrapper] ERROR: mktemp failed for consolidation child body (#${issue_number})" >>"$LOGFILE"
		return 1
	}
	printf '%s\n' "$child_body" >"$body_file"

	local child_url
	# t2115: Use gh_create_issue wrapper for origin label + signature auto-append.
	# origin:worker is kept in --label for explicitness (wrapper deduplicates).
	child_url=$(gh_create_issue --repo "$repo_slug" \
		--title "consolidation-task: merge thread on #${issue_number} into single spec" \
		--label "consolidation-task,auto-dispatch,origin:worker,tier:standard" \
		--body-file "$body_file" 2>/dev/null) || child_url=""
	rm -f "$body_file"

	# gh issue create prints the URL on success; extract the number.
	if [[ -n "$child_url" ]]; then
		printf '%s' "${child_url##*/}"
	fi
	return 0
}

#######################################
# t1982: Flag parent issue with needs-consolidation label and post the
# idempotent pointer comment linking to the newly created child issue.
# Called by _dispatch_issue_consolidation after successful child creation.
#
# Args: $1=issue_number $2=repo_slug $3=child_num $4=authors_csv
#######################################
_post_consolidation_dispatch_comment() {
	local issue_number="$1"
	local repo_slug="$2"
	local child_num="$3"
	local authors_csv="$4"

	gh issue edit "$issue_number" --repo "$repo_slug" \
		--add-label "needs-consolidation" 2>/dev/null || true

	local parent_comment_body="## Issue Consolidation Dispatched

A consolidation task has been filed as **#${child_num}**. It contains the full body and substantive comments of this issue inline, plus instructions for a worker to produce a merged spec, file it as a new issue, @mention all contributors, and close this issue as superseded.

**What happens next:**

1. A worker picks up #${child_num} on the next pulse cycle
2. It files a new consolidated issue with the merged spec
3. It comments \"Superseded by #NNN\" here, applies the \`consolidated\` label, and closes this issue
4. Contributors (${authors_csv:-_none detected_}) are @-mentioned on the new issue

_Automated by \`_dispatch_issue_consolidation()\` in \`pulse-triage.sh\` (t1982)_"

	_gh_idempotent_comment "$issue_number" "$repo_slug" \
		"## Issue Consolidation Dispatched" "$parent_comment_body"
	return 0
}

#######################################
# t1982/t2151: Dispatch a consolidation task for an issue with accumulated
# substantive comments. Creates a self-contained consolidation-task child
# issue that the pulse will pick up on the next cycle. The child's body
# contains the parent's title, body, and substantive comments inline so
# the worker never needs to read the parent.
#
# Idempotent: returns 0 without creating anything if a child already exists
# or if the cross-runner advisory lock is held by another runner.
#
# t2151 cross-runner coordination:
#   Phase A (t2144) closed single-runner cascade vectors. This path adds
#   the cross-runner guard: acquire `consolidation-in-progress` before
#   creating the child, release on any exit path (success or failure).
#   See `_consolidation_lock_acquire` for the full protocol.
#
# Reference pattern: `_issue_targets_large_files` at pulse-dispatch-core.sh:685-757
# which creates file-size-debt child issues the same way.
#######################################
_dispatch_issue_consolidation() {
	local issue_number="$1"
	local repo_slug="$2"
	local repo_path="$3"

	# Ensure labels exist on this repo up front. Idempotent (--force).
	_ensure_consolidation_labels "$repo_slug"

	# t2161: Safety net — skip dispatch if an open PR with a closing keyword
	# already resolves this parent. Mirrors the same guard in
	# _issue_needs_consolidation; checked here too because the dispatch path
	# is reachable from contributor runners on stale code where the gate
	# may have been satisfied at flag time but a fix PR landed since.
	# (Note: _backfill_stale_consolidation_labels has called the gate since
	# t2144/A2. This defence-in-depth remains for cross-runner version drift.)
	# Cheaper than _consolidation_child_exists (one PR search vs two issue
	# searches + label read) so it runs first.
	if _consolidation_resolving_pr_exists "$issue_number" "$repo_slug"; then
		echo "[pulse-wrapper] Consolidation: in-flight resolving PR exists for #${issue_number} in ${repo_slug}; skipping dispatch (t2161)" >>"$LOGFILE"
		return 0
	fi

	# Dedup: if an open consolidation-task already references this parent,
	# just ensure the parent is flagged and return. Do NOT create a duplicate.
	# t2151: _consolidation_child_exists also returns 0 when the lock label
	# is present, so a competing runner's in-flight creation blocks us here
	# before we ever touch the acquire path.
	if _consolidation_child_exists "$issue_number" "$repo_slug"; then
		gh issue edit "$issue_number" --repo "$repo_slug" \
			--add-label "needs-consolidation" 2>/dev/null || true
		echo "[pulse-wrapper] Consolidation: child already exists for #${issue_number} in ${repo_slug}; flagged parent and returning" >>"$LOGFILE"
		return 0
	fi

	# t2151: acquire the cross-runner advisory lock before any state changes
	# that would be expensive or visible to cause a partial-state race.
	# If we don't win the lock, another runner will create the child; we
	# just need to flag the parent as needing consolidation and return.
	if ! _consolidation_lock_acquire "$issue_number" "$repo_slug"; then
		gh issue edit "$issue_number" --repo "$repo_slug" \
			--add-label "needs-consolidation" 2>/dev/null || true
		echo "[pulse-wrapper] Consolidation: lock held by another runner for #${issue_number} in ${repo_slug}; flagged parent and yielding" >>"$LOGFILE"
		return 0
	fi

	# From this point on, every exit path MUST call _consolidation_lock_release.
	local self_login
	self_login=$(_consolidation_lock_self_login)

	# Fetch parent metadata.
	local parent_title parent_body parent_labels
	parent_title=$(gh issue view "$issue_number" --repo "$repo_slug" \
		--json title --jq '.title' 2>/dev/null) || parent_title=""
	parent_body=$(gh issue view "$issue_number" --repo "$repo_slug" \
		--json body --jq '.body // ""' 2>/dev/null) || parent_body=""
	parent_labels=$(gh issue view "$issue_number" --repo "$repo_slug" \
		--json labels --jq '[.labels[].name] | join(",")' 2>/dev/null) || parent_labels=""

	# Fetch substantive comments via the shared filter helper.
	local substantive_json
	substantive_json=$(_consolidation_substantive_comments "$issue_number" "$repo_slug")
	[[ -n "$substantive_json" ]] || substantive_json="[]"

	# Build the Contributors cc line (unique, @-prefixed).
	local authors_csv
	authors_csv=$(printf '%s' "$substantive_json" | jq -r '
		[.[] | .login] | unique | map("@" + .) | join(" ")
	' 2>/dev/null) || authors_csv=""

	# Compose the self-contained child body.
	local child_body
	child_body=$(_compose_consolidation_child_body \
		"$issue_number" "$repo_slug" "$parent_title" "$parent_body" \
		"$substantive_json" "$authors_csv" "$parent_labels")

	# File the child issue via a temp body file.
	local child_num
	child_num=$(_create_consolidation_child_issue "$repo_slug" "$issue_number" "$child_body")

	if [[ -z "$child_num" || ! "$child_num" =~ ^[0-9]+$ ]]; then
		echo "[pulse-wrapper] ERROR: consolidation child creation FAILED for #${issue_number} in ${repo_slug}" >>"$LOGFILE"
		# Still flag parent so it doesn't keep firing every cycle.
		gh issue edit "$issue_number" --repo "$repo_slug" \
			--add-label "needs-consolidation" 2>/dev/null || true
		# t2151: release the lock on failure too — otherwise TTL is the only
		# way it clears, and another runner would be blocked for 6h.
		_consolidation_lock_release "$issue_number" "$repo_slug" "$self_login"
		return 1
	fi

	# Flag parent and post the idempotent pointer comment.
	_post_consolidation_dispatch_comment "$issue_number" "$repo_slug" "$child_num" "$authors_csv"
	# t2151: release the lock — the child now exists on GitHub and
	# `_consolidation_child_exists` will block subsequent dispatches on
	# its own, making the lock unnecessary past this point.
	_consolidation_lock_release "$issue_number" "$repo_slug" "$self_login"
	echo "[pulse-wrapper] Consolidation: flagged #${issue_number} in ${repo_slug}, dispatched child #${child_num}" >>"$LOGFILE"
	return 0
}

#######################################
# t2151: Clear stale `consolidation-in-progress` lock labels whose oldest
# lock-marker comment is older than CONSOLIDATION_LOCK_TTL_HOURS. Covers
# the case where the runner that acquired the lock crashed or lost network
# between `_consolidation_lock_acquire` and `_consolidation_lock_release`,
# leaving the lock wedged.
#
# Called from _backfill_stale_consolidation_labels so every pulse cycle
# sweeps all pulse-enabled repos for stuck locks at zero marginal cost.
#
# Args: $1=repo_slug, $2=issue_number
# Returns: 0 if lock was cleared, 1 if lock was fresh (no action taken).
# Side effect: emits a log line when clearing.
#######################################
_consolidation_ttl_sweep_one() {
	local slug="$1"
	local num="$2"
	local ttl_hours="${CONSOLIDATION_LOCK_TTL_HOURS:-6}"
	[[ "$ttl_hours" =~ ^[0-9]+$ ]] || ttl_hours=6

	# Get the oldest lock-marker timestamp.
	local markers_json
	markers_json=$(_consolidation_lock_markers "$num" "$slug")
	[[ -n "$markers_json" ]] || markers_json="[]"

	local oldest_iso
	oldest_iso=$(printf '%s' "$markers_json" |
		jq -r '.[0].created_at // empty' 2>/dev/null) || oldest_iso=""

	if [[ -z "$oldest_iso" ]]; then
		# Label present but no marker comment — orphaned from a previous
		# deploy or manual edit. Clear it as well (nothing to tiebreak).
		gh issue edit "$num" --repo "$slug" \
			--remove-label "consolidation-in-progress" >/dev/null 2>&1 || true
		echo "[pulse-wrapper] Consolidation lock TTL sweep: cleared orphan (no marker) on #${num} in ${slug}" >>"$LOGFILE"
		return 0
	fi

	# Compute oldest-epoch. Prefer GNU date -d; fall back to BSD date -j.
	local oldest_epoch=""
	oldest_epoch=$(date -u -d "$oldest_iso" +'%s' 2>/dev/null) || oldest_epoch=""
	if [[ -z "$oldest_epoch" ]]; then
		oldest_epoch=$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$oldest_iso" +'%s' 2>/dev/null) || oldest_epoch=""
	fi
	# If date parsing fails entirely, fall-open (treat as fresh). A real
	# stuck lock will trip on the NEXT pulse cycle once the comment-ISO
	# parser recovers — preferable to false-clearing an in-flight lock.
	[[ -n "$oldest_epoch" ]] || return 1

	local now_epoch
	now_epoch=$(date -u +'%s' 2>/dev/null) || now_epoch=0
	local age_seconds=$((now_epoch - oldest_epoch))
	local ttl_seconds=$((ttl_hours * 3600))

	if [[ "$age_seconds" -lt "$ttl_seconds" ]]; then
		return 1
	fi

	# Lock is stale — clear the label and delete ALL markers (nobody is
	# coming back for them; the next dispatcher starts from scratch).
	gh issue edit "$num" --repo "$slug" \
		--remove-label "consolidation-in-progress" >/dev/null 2>&1 || true
	local mid
	while IFS= read -r mid; do
		[[ -z "$mid" ]] && continue
		gh api -X DELETE "repos/${slug}/issues/comments/${mid}" >/dev/null 2>&1 || true
	done < <(printf '%s' "$markers_json" | jq -r '.[].id' 2>/dev/null)

	echo "[pulse-wrapper] Consolidation lock TTL sweep: cleared stale lock on #${num} in ${slug} (age=${age_seconds}s, ttl=${ttl_seconds}s)" >>"$LOGFILE"
	return 0
}

#######################################
# t1982/t2151: Backfill pass for stuck needs-consolidation issues.
#
# The re-evaluation pass (_reevaluate_consolidation_labels) only *clears*
# stale labels when the comment filter no longer triggers. Issues flagged
# before this fix landed never got a consolidation-task child created,
# because the old _dispatch_issue_consolidation() just labelled and
# returned. Those issues sit forever behind the needs-* dispatch filter.
#
# This pass sweeps every open needs-consolidation issue without a linked
# consolidation-task child and dispatches one retroactively.
#
# t2151: Also sweeps every open `consolidation-in-progress` issue and
# clears the lock label when the oldest lock-marker comment is older than
# CONSOLIDATION_LOCK_TTL_HOURS (default 6h). Closes the "runner crashed
# mid-dispatch" failure mode in which the lock would otherwise sit wedged
# until a human notices.
#
# Runs every pulse cycle alongside _reevaluate_consolidation_labels.
# Cheap: one gh issue list per repo + one child-exists lookup per labelled
# issue, then dispatch only for those missing a child.
#######################################
_backfill_stale_consolidation_labels() {
	local repos_json="$REPOS_JSON"
	[[ -f "$repos_json" ]] || return 0

	local total_backfilled=0
	local total_cleared_stale=0
	local total_locks_expired=0
	while IFS='|' read -r slug rpath; do
		[[ -n "$slug" ]] || continue

		# t2151: TTL sweep for stuck `consolidation-in-progress` labels.
		# Separate query from needs-consolidation because a lock can be held
		# on a parent that already has both labels (lock was acquired before
		# needs-consolidation was applied) or only the lock (acquire path
		# where child creation failed after lock but before flag-parent).
		local locked_issues_json
		locked_issues_json=$(gh issue list --repo "$slug" --state open \
			--label "consolidation-in-progress" \
			--json number --limit 50 2>/dev/null) || locked_issues_json='[]'
		local locked_num
		while IFS= read -r locked_num; do
			[[ "$locked_num" =~ ^[0-9]+$ ]] || continue
			if _consolidation_ttl_sweep_one "$slug" "$locked_num"; then
				total_locks_expired=$((total_locks_expired + 1))
			fi
		done < <(printf '%s' "$locked_issues_json" | jq -r '.[]?.number // ""' 2>/dev/null)

		local issues_json
		issues_json=$(gh issue list --repo "$slug" --state open \
			--label "needs-consolidation" \
			--json number,labels --limit 50 2>/dev/null) || issues_json='[]'

		while IFS='|' read -r num labels_csv; do
			[[ "$num" =~ ^[0-9]+$ ]] || continue

			# t2144 (A3): Defense in depth — skip and auto-clear if the
			# parent already carries `consolidated`. _issue_needs_consolidation
			# short-circuits on this label (line ~263), but that function
			# won't clean up the stale `needs-consolidation` label if both
			# are present; do it here explicitly.
			if [[ ",${labels_csv}," == *",consolidated,"* ]]; then
				gh issue edit "$num" --repo "$slug" \
					--remove-label "needs-consolidation" >/dev/null 2>&1 || true
				total_cleared_stale=$((total_cleared_stale + 1))
				continue
			fi

			# t2144 (A2): Unify the dispatch guard. Prior to this, backfill
			# ran a bare label-lookup + open-child-exists check and dispatched
			# on anything that passed, bypassing the filter that
			# _issue_needs_consolidation enforces on the main pre-dispatch
			# path. The delegation here:
			#   - auto-clears the label when the filter no longer triggers
			#     (via the was_already_labeled branch inside the helper)
			#   - short-circuits on an open or recently-closed child via
			#     _consolidation_child_exists (now grace-windowed, A4)
			#   - short-circuits on the `consolidated` label
			# Net effect: backfill only dispatches when dispatch is actually
			# warranted under the current filter, eliminating the cascade.
			if ! _issue_needs_consolidation "$num" "$slug"; then
				continue
			fi
			if _dispatch_issue_consolidation "$num" "$slug" "$rpath"; then
				total_backfilled=$((total_backfilled + 1))
			fi
		done < <(printf '%s' "$issues_json" | jq -r '.[] | "\(.number)|\([.labels[].name] | join(","))"' 2>/dev/null)
	done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | "\(.slug)|\(.path // "")"' "$repos_json" 2>/dev/null)

	if [[ "$total_backfilled" -gt 0 ]]; then
		echo "[pulse-wrapper] Consolidation backfill: dispatched ${total_backfilled} stale consolidation child issue(s)" >>"$LOGFILE"
	fi
	if [[ "$total_cleared_stale" -gt 0 ]]; then
		echo "[pulse-wrapper] Consolidation backfill: cleared ${total_cleared_stale} stale needs-consolidation label(s) on already-consolidated parents (t2144)" >>"$LOGFILE"
	fi
	if [[ "$total_locks_expired" -gt 0 ]]; then
		echo "[pulse-wrapper] Consolidation backfill: cleared ${total_locks_expired} stale consolidation-in-progress lock(s) (t2151 TTL)" >>"$LOGFILE"
	fi
	return 0
}
