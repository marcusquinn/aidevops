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

		while read -r num; do
			[[ "$num" =~ ^[0-9]+$ ]] || continue
			# _issue_needs_consolidation returns 1 (no consolidation needed)
			# AND auto-clears the label when was_already_labeled=true
			if ! _issue_needs_consolidation "$num" "$slug"; then
				total_cleared=$((total_cleared + 1))
			fi
		done < <(printf '%s' "$issues_json" | jq -r '.[].number' 2>/dev/null)
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

		while read -r num; do
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
			fi
		done < <(printf '%s' "$issues_json" | jq -r '.[].number' 2>/dev/null)
	done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "" and .path != "") | "\(.slug)|\(.path)"' "$repos_json" 2>/dev/null)

	if [[ "$total_cleared" -gt 0 ]]; then
		echo "[pulse-wrapper] Simplification re-evaluation: cleared ${total_cleared} stale needs-simplification label(s)" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# t1982: Check whether an open consolidation-task child issue already
# references this parent. Used by both _issue_needs_consolidation (as a
# pre-filter) and _dispatch_issue_consolidation (as an idempotency guard)
# so that repeat calls on the same parent do not create duplicate children.
#
# Uses GitHub's `in:body` search over the consolidation-task label scope.
# The child body always contains the literal token "Consolidation target: #NNN"
# (see _compose_consolidation_child_body) which is the searchable anchor.
#
# Returns: 0 if an open child exists, 1 if none (or on lookup failure).
#######################################
_consolidation_child_exists() {
	local parent_num="$1"
	local repo_slug="$2"

	[[ -n "$parent_num" && -n "$repo_slug" ]] || return 1

	local child_count
	child_count=$(gh issue list --repo "$repo_slug" --state open \
		--label "consolidation-task" \
		--search "in:body \"Consolidation target: #${parent_num}\"" \
		--json number --jq 'length' --limit 5 2>/dev/null) || child_count=0
	[[ "$child_count" =~ ^[0-9]+$ ]] || child_count=0
	[[ "$child_count" -gt 0 ]]
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

	local min_chars="${ISSUE_CONSOLIDATION_COMMENT_MIN_CHARS:-200}"

	printf '%s' "$comments_json" | jq --argjson min "$min_chars" '
		[.[] | select(
			(.body | length) >= $min
			and (.user.type != "Bot")
			and (.body | test("DISPATCH_CLAIM nonce=") | not)
			and (.body | test("^(<!-- ops:start[^>]*-->\\s*)?Dispatching worker") | not)
			and (.body | test("^<!-- (nmr-hold|aidevops-signed|ops:start|provenance:start)") | not)
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
  --label "consolidated,origin:worker,<copy relevant labels from parent, excluding needs-consolidation and consolidation-task>" \\
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
	return 0
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
	child_url=$(gh issue create --repo "$repo_slug" \
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
# t1982: Dispatch a consolidation task for an issue with accumulated
# substantive comments. Creates a self-contained consolidation-task child
# issue that the pulse will pick up on the next cycle. The child's body
# contains the parent's title, body, and substantive comments inline so
# the worker never needs to read the parent.
#
# Idempotent: returns 0 without creating anything if a child already exists.
#
# Reference pattern: `_issue_targets_large_files` at pulse-dispatch-core.sh:685-757
# which creates simplification-debt child issues the same way.
#######################################
_dispatch_issue_consolidation() {
	local issue_number="$1"
	local repo_slug="$2"
	local repo_path="$3"

	# Ensure labels exist on this repo up front. Idempotent (--force).
	_ensure_consolidation_labels "$repo_slug"

	# Dedup: if an open consolidation-task already references this parent,
	# just ensure the parent is flagged and return. Do NOT create a duplicate.
	if _consolidation_child_exists "$issue_number" "$repo_slug"; then
		gh issue edit "$issue_number" --repo "$repo_slug" \
			--add-label "needs-consolidation" 2>/dev/null || true
		echo "[pulse-wrapper] Consolidation: child already exists for #${issue_number} in ${repo_slug}; flagged parent and returning" >>"$LOGFILE"
		return 0
	fi

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
		return 1
	fi

	# Flag parent and post the idempotent pointer comment.
	_post_consolidation_dispatch_comment "$issue_number" "$repo_slug" "$child_num" "$authors_csv"
	echo "[pulse-wrapper] Consolidation: flagged #${issue_number} in ${repo_slug}, dispatched child #${child_num}" >>"$LOGFILE"
	return 0
}

#######################################
# t1982: Backfill pass for stuck needs-consolidation issues.
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
# Runs every pulse cycle alongside _reevaluate_consolidation_labels.
# Cheap: one gh issue list per repo + one child-exists lookup per labelled
# issue, then dispatch only for those missing a child.
#######################################
_backfill_stale_consolidation_labels() {
	local repos_json="$REPOS_JSON"
	[[ -f "$repos_json" ]] || return 0

	local total_backfilled=0
	while IFS='|' read -r slug rpath; do
		[[ -n "$slug" ]] || continue
		local issues_json
		issues_json=$(gh issue list --repo "$slug" --state open \
			--label "needs-consolidation" \
			--json number --limit 50 2>/dev/null) || issues_json="[]"

		while read -r num; do
			[[ "$num" =~ ^[0-9]+$ ]] || continue
			# Skip if a child already exists — the dispatch path is
			# already idempotent but short-circuiting saves API calls.
			if _consolidation_child_exists "$num" "$slug"; then
				continue
			fi
			if _dispatch_issue_consolidation "$num" "$slug" "$rpath"; then
				total_backfilled=$((total_backfilled + 1))
			fi
		done < <(printf '%s' "$issues_json" | jq -r '.[].number' 2>/dev/null)
	done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | "\(.slug)|\(.path // "")"' "$repos_json" 2>/dev/null)

	if [[ "$total_backfilled" -gt 0 ]]; then
		echo "[pulse-wrapper] Consolidation backfill: dispatched ${total_backfilled} stale consolidation child issue(s)" >>"$LOGFILE"
	fi
	return 0
}
