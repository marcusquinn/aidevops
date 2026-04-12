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
#   - _dispatch_issue_consolidation

[[ -n "${_PULSE_TRIAGE_LOADED:-}" ]] && return 0
_PULSE_TRIAGE_LOADED=1

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
	if [[ "$entity_type" == "pr" ]]; then
		gh pr comment "$entity_number" --repo "$repo_slug" \
			--body "$comment_body" 2>/dev/null || true
	else
		gh issue comment "$entity_number" --repo "$repo_slug" \
			--body "$comment_body" 2>/dev/null || true
	fi

	echo "[pulse-wrapper] _gh_idempotent_comment: posted gate comment on #${entity_number} in ${repo_slug} (marker: ${marker:0:40}...)" >>"$LOGFILE"
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
	# If already labeled, re-evaluate with the current (tighter) filter.
	# If the issue no longer triggers, auto-clear the label so it becomes
	# dispatchable without manual intervention. This handles the case where
	# a filter improvement makes previously-flagged issues pass.
	local was_already_labeled=false
	if [[ ",$issue_labels," == *",needs-consolidation,"* ]]; then
		was_already_labeled=true
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
	local min_chars="$ISSUE_CONSOLIDATION_COMMENT_MIN_CHARS"
	substantive_count=$(printf '%s' "$comments_json" | jq --argjson min "$min_chars" '
		[.[] | select(
			(.body | length) >= $min
			and (.user.type != "Bot")
			and (.body | test("DISPATCH_CLAIM nonce=") | not)
			and (.body | test("^(<!-- ops:start[^>]*-->\\s*)?Dispatching worker") | not)
			and (.body | test("^<!-- (nmr-hold|aidevops-signed|ops:start|provenance:start)") | not)
			and (.body | test("CLAIM_RELEASED reason=") | not)
			and (.body | test("^(Worker failed:|## Worker Watchdog Kill)") | not)
			and (.body | test("^(\\*\\*)?Stale assignment recovered") | not)
			and (.body | test("^## (Triage Review|Completion Summary|Large File Simplification Gate|Issue Consolidation Needed|Additional Review Feedback|Cascade Tier Escalation)") | not)
			and (.body | test("^This quality-debt issue was auto-generated by") | not)
			and (.body | test("<!-- MERGE_SUMMARY -->") | not)
			and (.body | test("^Closing:") | not)
			and (.body | test("^Worker failed: orphan worktree") | not)
			and (.body | test("sudo aidevops approve") | not)
			and (.body | test("^_Automated by") | not)
		)] | length
	' 2>/dev/null) || substantive_count=0

	if [[ "$substantive_count" -ge "$ISSUE_CONSOLIDATION_COMMENT_THRESHOLD" ]]; then
		return 0
	fi

	# Auto-clear: if the issue was previously labeled but no longer triggers
	# (e.g., filter improvement excluded operational comments that were false
	# positives), remove the label so it becomes dispatchable immediately.
	if [[ "$was_already_labeled" == "true" ]]; then
		gh issue edit "$issue_number" --repo "$repo_slug" \
			--remove-label "needs-consolidation" >/dev/null 2>&1 || true
		echo "[pulse-wrapper] Consolidation gate cleared for #${issue_number} (${repo_slug}) — substantive_count=${substantive_count} below threshold=${ISSUE_CONSOLIDATION_COMMENT_THRESHOLD}" >>"$LOGFILE"
	fi
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
		local count
		count=$(printf '%s' "$issues_json" | jq 'length' 2>/dev/null) || count=0
		[[ "$count" -gt 0 ]] || continue

		local i=0
		while [[ "$i" -lt "$count" ]]; do
			local num
			num=$(printf '%s' "$issues_json" | jq -r ".[$i].number" 2>/dev/null)
			i=$((i + 1))
			[[ "$num" =~ ^[0-9]+$ ]] || continue
			# _issue_needs_consolidation returns 1 (no consolidation needed)
			# AND auto-clears the label when was_already_labeled=true
			if ! _issue_needs_consolidation "$num" "$slug"; then
				total_cleared=$((total_cleared + 1))
			fi
		done
	done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | .slug' "$repos_json" 2>/dev/null)

	if [[ "$total_cleared" -gt 0 ]]; then
		echo "[pulse-wrapper] Consolidation re-evaluation: cleared ${total_cleared} stale needs-consolidation label(s)" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# Re-evaluate needs-simplification labeled issues across pulse repos.
# Same pattern as _reevaluate_consolidation_labels: issues filtered out
# by the needs-* exclusion never reach dispatch_with_dedup, so the
# auto-clear at the end of _issue_targets_large_files can't fire.
# This pass re-evaluates them and clears the label when the file is
# now excluded (lockfile, JSON config) or below threshold.
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
		local count
		count=$(printf '%s' "$issues_json" | jq 'length' 2>/dev/null) || count=0
		[[ "$count" -gt 0 ]] || continue

		local i=0
		while [[ "$i" -lt "$count" ]]; do
			local num
			num=$(printf '%s' "$issues_json" | jq -r ".[$i].number" 2>/dev/null)
			i=$((i + 1))
			[[ "$num" =~ ^[0-9]+$ ]] || continue
			local body
			body=$(gh issue view "$num" --repo "$slug" \
				--json body --jq '.body // ""' 2>/dev/null) || body=""
			# _issue_targets_large_files returns 1 (no large files) AND
			# auto-clears the label when was_already_labeled
			if ! _issue_targets_large_files "$num" "$slug" "$body" "$rpath"; then
				total_cleared=$((total_cleared + 1))
			fi
		done
	done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "" and .path != "") | "\(.slug)|\(.path)"' "$repos_json" 2>/dev/null)

	if [[ "$total_cleared" -gt 0 ]]; then
		echo "[pulse-wrapper] Simplification re-evaluation: cleared ${total_cleared} stale needs-simplification label(s)" >>"$LOGFILE"
	fi
	return 0
}

_dispatch_issue_consolidation() {
	local issue_number="$1"
	local repo_slug="$2"
	local repo_path="$3"

	# Add label so we don't re-trigger on next cycle
	gh label create "needs-consolidation" \
		--repo "$repo_slug" \
		--description "Issue needs comment consolidation before dispatch" \
		--color "FBCA04" \
		--force 2>/dev/null || true
	gh issue edit "$issue_number" --repo "$repo_slug" \
		--add-label "needs-consolidation" 2>/dev/null || true

	# Post comment explaining the hold (idempotent — safe against concurrent pulses)
	local comment_body="## Issue Consolidation Needed

This issue has accumulated multiple substantive comments that modify the original scope. To give the implementing worker clean context, a consolidation pass will merge the issue body and comment addenda into a single coherent specification.

**What happens next:**
1. A consolidation worker reads the body + all substantive comments
2. Creates a new issue with the merged spec (body-only, no comment archaeology)
3. Links the new issue back here: \"Supersedes #${issue_number}\"
4. This issue is closed as superseded

The implementing worker gets a single clean body with all context inline.

_Automated by \`_dispatch_issue_consolidation()\` in pulse-wrapper.sh_"

	_gh_idempotent_comment "$issue_number" "$repo_slug" \
		"## Issue Consolidation Needed" "$comment_body"

	echo "[pulse-wrapper] Issue consolidation: flagged #${issue_number} in ${repo_slug} for comment consolidation" >>"$LOGFILE"
	return 0
}
