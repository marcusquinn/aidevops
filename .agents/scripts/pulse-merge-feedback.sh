#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-merge-feedback.sh — Worker-PR feedback routing for the deterministic merge pass.
#
# Extracted from pulse-merge.sh (GH#19836) to bring that file below the
# 2000-line simplification gate.
#
# This module contains the "route feedback to linked issue + close PR"
# cluster: the three dispatch helpers invoked by _check_pr_merge_gates
# when a worker-authored PR hits a dead-end state (CI red, conflicts
# unresolvable by update-branch, or CHANGES_REQUESTED review). Each
# helper appends a feedback section to the linked issue body (marker-
# guarded for idempotency), transitions the issue to status:available,
# and closes the PR so the dispatch queue can re-pick the work.
#
# None of these functions call back into the merge core or pr-gates
# clusters — they only call low-level `gh` commands, `set_issue_status`
# from shared-constants.sh, and the local `_build_review_feedback_section`
# helper. Safe to extract into its own module.
#
# This module is sourced by pulse-wrapper.sh AFTER pulse-merge.sh and
# pulse-merge-conflict.sh. It MUST NOT be executed directly — it relies
# on the orchestrator having sourced shared-constants.sh and having
# defined all PULSE_* configuration constants in the bootstrap section.
#
# Functions in this module (in source order):
#   - _build_review_feedback_section      (t2093)
#   - _dispatch_ci_fix_worker             (t2093 follow-up)
#   - _dispatch_conflict_fix_worker       (t2093 follow-up)
#   - _dispatch_pr_fix_worker             (t2093)
#
# All functions fail-open: missing helpers, API errors, or malformed
# state never block the merge pass — they log and return 0.

# Include guard — prevent double-sourcing.
[[ -n "${_PULSE_MERGE_FEEDBACK_LOADED:-}" ]] && return 0
_PULSE_MERGE_FEEDBACK_LOADED=1

#######################################
# Build the markdown "Review Feedback" section for routing to a linked
# issue (t2093).
#
# Reads already-fetched review + inline-comment JSON arrays and produces a
# human-readable section with file:line citations. The section is scoped
# to a single closing PR so the marker in `_dispatch_pr_fix_worker` can
# prevent duplicate appends if the merge pass re-encounters the same PR
# before the close propagates.
#
# Args:
#   $1 - pr_number
#   $2 - repo_slug
#   $3 - reviews_json    (JSON array of {author,state,body,url})
#   $4 - inline_json     (JSON array of {author,path,line,body,url})
#
# Output: markdown section on stdout (empty string if no content).
#######################################
_build_review_feedback_section() {
	local pr_number="$1"
	local repo_slug="$2"
	local reviews_json="${3:-[]}"
	local inline_json="${4:-[]}"

	local reviews_count inline_count
	reviews_count=$(printf '%s' "$reviews_json" | jq 'length' 2>/dev/null) || reviews_count=0
	inline_count=$(printf '%s' "$inline_json" | jq 'length' 2>/dev/null) || inline_count=0
	[[ "$reviews_count" =~ ^[0-9]+$ ]] || reviews_count=0
	[[ "$inline_count" =~ ^[0-9]+$ ]] || inline_count=0

	if [[ "$reviews_count" -eq 0 && "$inline_count" -eq 0 ]]; then
		return 0
	fi

	local header
	header="## Review Feedback routed from PR #${pr_number} (t2093)

This section was auto-generated when the deterministic merge pass detected
\`reviewDecision=CHANGES_REQUESTED\` on the linked worker PR. The PR has been
closed and this issue re-entered the dispatch queue. The next worker should
address the findings below and open a fresh PR against this issue.

See the original PR for full context: https://github.com/${repo_slug}/pull/${pr_number}
"

	local reviews_md=""
	if [[ "$reviews_count" -gt 0 ]]; then
		reviews_md=$(printf '%s' "$reviews_json" | jq -r '
			.[] | "- **@\(.author)** (`\(.state)`): \(((.body // "") | gsub("\r"; "") | split("\n")[0])[0:300])\n  [view review](\(.url // ""))"
		' 2>/dev/null) || reviews_md=""
	fi

	local inline_md=""
	if [[ "$inline_count" -gt 0 ]]; then
		inline_md=$(printf '%s' "$inline_json" | jq -r '
			.[] | "- **@\(.author)** `\(.path)`:\(.line // "?") — \(((.body // "") | gsub("\r"; "") | split("\n")[0])[0:300])\n  [view comment](\(.url // ""))"
		' 2>/dev/null) || inline_md=""
	fi

	printf '%s\n' "$header"
	if [[ -n "$reviews_md" ]]; then
		printf '### Top-level reviews\n\n%s\n\n' "$reviews_md"
	fi
	if [[ -n "$inline_md" ]]; then
		printf '### Inline comments (file:line citations)\n\n%s\n\n' "$inline_md"
	fi
	return 0
}

#######################################
# Route CI failure feedback from a worker PR to its linked issue, close
# the PR, and set the issue to status:available for re-dispatch.
#
# The next worker sees the failing check names, URLs, and context in the
# issue body and can address the failures directly. This closes the gap
# where worker PRs with red CI sit indefinitely — the merge pass skips
# them (correctly), but nothing dispatches a fix worker.
#
# Same pattern as _dispatch_pr_fix_worker (t2093) but for CI failures
# instead of review CHANGES_REQUESTED.
#
# Args: $1=pr_number, $2=repo_slug, $3=linked_issue
#######################################
_dispatch_ci_fix_worker() {
	local pr_number="$1"
	local repo_slug="$2"
	local linked_issue="$3"

	[[ "$pr_number" =~ ^[0-9]+$ ]] || return 0
	[[ -n "$repo_slug" ]] || return 0
	[[ "$linked_issue" =~ ^[0-9]+$ ]] || return 0

	# Create labels (idempotent, --force)
	gh label create "ci-feedback-routed" --repo "$repo_slug" --color "E4E669" \
		--description "Worker PR with failing CI routed to linked issue for re-dispatch" \
		--force >/dev/null 2>&1 || true
	gh label create "source:ci-feedback" --repo "$repo_slug" --color "FEF2C0" \
		--description "Issue carries CI failure feedback routed from a closed worker PR" \
		--force >/dev/null 2>&1 || true

	# Collect failing checks: name, status, URL
	local failing_checks
	failing_checks=$(gh pr checks "$pr_number" --repo "$repo_slug" --required \
		--json name,bucket,link \
		--jq '[.[] | select(.bucket == "fail" or .bucket == "cancel")
			| "- **\(.name)**: \(.bucket) — [\(.link // "no link")](\(.link // ""))"]
			| join("\n")' \
		2>/dev/null) || failing_checks=""

	if [[ -z "$failing_checks" ]]; then
		echo "[pulse-wrapper] _dispatch_ci_fix_worker: PR #${pr_number} in ${repo_slug} has failing checks but could not collect details — skipping routing" >>"$LOGFILE"
		return 0
	fi

	# Build the CI Failure Feedback section
	local feedback_section
	feedback_section="## CI Failure Feedback (from PR #${pr_number})

The previous worker's PR #${pr_number} had failing required CI checks. The PR has been
closed and this issue re-queued for dispatch. The next worker should address these failures.

### Failing checks

${failing_checks}

### Worker guidance

1. Check out a fresh branch from \`origin/main\` (do NOT reuse the old branch)
2. Read the failing check URLs above for specific error messages
3. Fix the issues in the code, not in the CI config
4. Ensure all checks pass locally before pushing

_Routed by deterministic merge pass (pulse-merge.sh)._"

	# Append to issue body (marker-guarded for idempotency)
	# t2383 Fix 5: fail-safe — skip body edit when issue fetch fails to prevent
	# clobbering the issue body with only the routed-feedback section.
	local current_body ci_fetch_rc
	ci_fetch_rc=0
	current_body=$(gh issue view "$linked_issue" --repo "$repo_slug" \
		--json body --jq '.body // ""' 2>/dev/null) || ci_fetch_rc=$?
	if [[ $ci_fetch_rc -ne 0 ]]; then
		echo "[pulse-wrapper] _dispatch_ci_fix_worker: failed to fetch issue #${linked_issue} body (exit ${ci_fetch_rc}) — skipping body edit to prevent data loss (t2383)" >>"$LOGFILE"
		return 0
	fi

	local marker="<!-- ci-feedback:PR${pr_number} -->"
	if printf '%s' "$current_body" | grep -qF "$marker"; then
		echo "[pulse-wrapper] _dispatch_ci_fix_worker: issue #${linked_issue} already has CI feedback for PR #${pr_number} — skipping" >>"$LOGFILE"
	else
		local new_body="${current_body}

${marker}
${feedback_section}"
		gh issue edit "$linked_issue" --repo "$repo_slug" \
			--body "$new_body" >/dev/null 2>&1 || {
			echo "[pulse-wrapper] _dispatch_ci_fix_worker: failed to update issue #${linked_issue} body — aborting" >>"$LOGFILE"
			return 1
		}
	fi

	# Transition issue to available for re-dispatch
	if declare -F set_issue_status >/dev/null 2>&1; then
		set_issue_status "$linked_issue" "$repo_slug" "available" \
			--add-label "source:ci-feedback" >/dev/null 2>&1 || true
	else
		gh issue edit "$linked_issue" --repo "$repo_slug" \
			--add-label "status:available" --add-label "source:ci-feedback" \
			--remove-label "status:queued" --remove-label "status:in-progress" \
			--remove-label "status:in-review" --remove-label "status:claimed" \
			>/dev/null 2>&1 || true
	fi

	# Close the PR
	gh pr close "$pr_number" --repo "$repo_slug" \
		--comment "## CI failure feedback routed to issue #${linked_issue}

This worker PR had failing required CI checks. The failure details have been appended
to the linked issue body so the next worker can address them.

Failing checks:
${failing_checks}

_Closed by deterministic merge pass (pulse-merge.sh)._" \
		>/dev/null 2>&1 || true

	gh pr edit "$pr_number" --repo "$repo_slug" \
		--add-label "ci-feedback-routed" >/dev/null 2>&1 || true

	echo "[pulse-wrapper] _dispatch_ci_fix_worker: routed CI failure feedback from PR #${pr_number} to issue #${linked_issue} in ${repo_slug}" >>"$LOGFILE"
	return 0
}

#######################################
# Route merge conflict context from a worker PR to its linked issue, close
# the PR, and set the issue to status:available for re-dispatch.
#
# Called when `gh pr update-branch` fails (true semantic conflict) on a
# worker PR. The next worker gets the conflict context and the list of
# conflicting files in its prompt.
#
# Args: $1=pr_number, $2=repo_slug, $3=linked_issue, $4=pr_title
#######################################
_dispatch_conflict_fix_worker() {
	local pr_number="$1"
	local repo_slug="$2"
	local linked_issue="$3"
	local pr_title="$4"

	[[ "$pr_number" =~ ^[0-9]+$ ]] || return 0
	[[ -n "$repo_slug" ]] || return 0
	[[ "$linked_issue" =~ ^[0-9]+$ ]] || return 0

	# Create labels (idempotent, --force)
	gh label create "conflict-feedback-routed" --repo "$repo_slug" --color "D4C5F9" \
		--description "Worker PR with merge conflicts routed to linked issue for re-dispatch" \
		--force >/dev/null 2>&1 || true
	gh label create "source:conflict-feedback" --repo "$repo_slug" --color "E6D8FA" \
		--description "Issue carries conflict context routed from a closed worker PR" \
		--force >/dev/null 2>&1 || true

	# Get the list of files changed in the PR (these are the conflict candidates)
	local pr_files
	pr_files=$(gh pr view "$pr_number" --repo "$repo_slug" \
		--json files --jq '[.files[].path] | join("\n")' 2>/dev/null) || pr_files="(could not fetch)"

	local feedback_section
	feedback_section="## Merge Conflict Feedback (from PR #${pr_number})

The previous worker's PR #${pr_number} (\`${pr_title}\`) developed merge conflicts with
\`main\` that could not be resolved by \`gh pr update-branch\` (server-side fast-forward).
The conflicts are semantic — the same files were modified on both branches.

### Files in the conflicting PR

\`\`\`
${pr_files}
\`\`\`

### Worker guidance

1. Check out a fresh branch from \`origin/main\` (do NOT reuse the old PR's branch)
2. Re-implement the changes on top of the current \`main\`
3. The files listed above were modified by both this PR and concurrent merges — review \`main\` to understand what changed

_Routed by deterministic merge pass (pulse-merge.sh)._"

	# Append to issue body (marker-guarded)
	# t2383 Fix 5: fail-safe — skip body edit when issue fetch fails to prevent
	# clobbering the issue body with only the routed-feedback section.
	local current_body conflict_fetch_rc
	conflict_fetch_rc=0
	current_body=$(gh issue view "$linked_issue" --repo "$repo_slug" \
		--json body --jq '.body // ""' 2>/dev/null) || conflict_fetch_rc=$?
	if [[ $conflict_fetch_rc -ne 0 ]]; then
		echo "[pulse-wrapper] _dispatch_conflict_fix_worker: failed to fetch issue #${linked_issue} body (exit ${conflict_fetch_rc}) — skipping body edit to prevent data loss (t2383)" >>"$LOGFILE"
		return 0
	fi

	local marker="<!-- conflict-feedback:PR${pr_number} -->"
	if printf '%s' "$current_body" | grep -qF "$marker"; then
		echo "[pulse-wrapper] _dispatch_conflict_fix_worker: issue #${linked_issue} already has conflict feedback for PR #${pr_number} — skipping" >>"$LOGFILE"
	else
		local new_body="${current_body}

${marker}
${feedback_section}"
		gh issue edit "$linked_issue" --repo "$repo_slug" \
			--body "$new_body" >/dev/null 2>&1 || {
			echo "[pulse-wrapper] _dispatch_conflict_fix_worker: failed to update issue #${linked_issue} body — aborting" >>"$LOGFILE"
			return 1
		}
	fi

	# Transition issue to available
	if declare -F set_issue_status >/dev/null 2>&1; then
		set_issue_status "$linked_issue" "$repo_slug" "available" \
			--add-label "source:conflict-feedback" >/dev/null 2>&1 || true
	else
		gh issue edit "$linked_issue" --repo "$repo_slug" \
			--add-label "status:available" --add-label "source:conflict-feedback" \
			--remove-label "status:queued" --remove-label "status:in-progress" \
			--remove-label "status:in-review" --remove-label "status:claimed" \
			>/dev/null 2>&1 || true
	fi

	# Close the PR
	gh pr close "$pr_number" --repo "$repo_slug" \
		--comment "## Merge conflict feedback routed to issue #${linked_issue}

This worker PR had semantic merge conflicts with \`main\` that \`update-branch\` could not resolve. The conflict context and file list have been appended to the linked issue body so the next worker can re-implement on top of current \`main\`.

_Closed by deterministic merge pass (pulse-merge.sh)._" \
		>/dev/null 2>&1 || true

	gh pr edit "$pr_number" --repo "$repo_slug" \
		--add-label "conflict-feedback-routed" >/dev/null 2>&1 || true

	echo "[pulse-wrapper] _dispatch_conflict_fix_worker: routed conflict feedback from PR #${pr_number} to issue #${linked_issue} in ${repo_slug}" >>"$LOGFILE"
	return 0
}

#######################################
# Route review feedback from a stuck worker PR to its linked issue and
# close the PR so the dispatch queue can re-pick the task (t2093).
#
# Called by `_check_pr_merge_gates` when `reviewDecision=CHANGES_REQUESTED`
# on a worker-authored PR with a linked issue. Before this helper existed,
# such PRs accumulated indefinitely: the merge pass skipped them (correctly,
# since they can't pass the review gate as-is), but nothing dispatched a
# fresh worker to address the feedback. The PR author is the headless
# worker account, so no human was notified; the review-followup pipeline
# only fires on *merged* PRs; and the dispatch-dedup guard treated the
# open PR as an active claim on the linked issue.
#
# This function closes that loop:
#   1. Fetches bot reviews + inline comments from the stuck PR.
#   2. Appends a "Review Feedback" section to the linked issue body
#      (marker-guarded so re-runs are idempotent).
#   3. Transitions the linked issue to `status:available` and tags it
#      `source:review-feedback` so the next dispatch cycle picks it up
#      with the feedback in the prompt.
#   4. Closes the stuck PR with an explanatory comment and tags it
#      `review-routed-to-issue` as a belt-and-suspenders idempotency flag.
#
# Interactive PRs and external-contributor PRs are filtered out by the
# caller (`_check_pr_merge_gates`) — they have their own review flows.
#
# Fail-open: any API failure is logged and swallowed. The merge pass must
# continue processing other PRs.
#
# Reference patterns:
#   - `quality-feedback-helper.sh` — bot review comment extraction
#   - `_close_conflicting_pr`      — close-with-comment boilerplate
#   - `draft-response-helper.sh`   — issue body append pattern
#
# Args:
#   $1 - pr_number
#   $2 - repo_slug  (owner/repo)
#   $3 - linked_issue  (the issue the PR resolves/fixes/closes)
#######################################
_dispatch_pr_fix_worker() {
	local pr_number="$1"
	local repo_slug="$2"
	local linked_issue="$3"

	[[ "$pr_number" =~ ^[0-9]+$ ]] || return 0
	[[ -n "$repo_slug" ]] || return 0
	[[ "$linked_issue" =~ ^[0-9]+$ ]] || return 0

	# Ensure the idempotency + origin labels exist on the repo (idempotent,
	# --force, swallowed failures). quality-feedback-helper.sh also creates
	# source:review-feedback — redundant creation is harmless.
	gh label create "review-routed-to-issue" --repo "$repo_slug" --color "D93F0B" \
		--description "Worker PR with CHANGES_REQUESTED routed to linked issue for re-dispatch (t2093)" \
		--force >/dev/null 2>&1 || true
	gh label create "source:review-feedback" --repo "$repo_slug" --color "C2E0C6" \
		--description "Issue carries review feedback routed from a closed worker PR" \
		--force >/dev/null 2>&1 || true

	# --- Fetch bot/human reviews (substantive: CHANGES_REQUESTED or long body) ---
	local reviews_json
	reviews_json=$(gh api "repos/${repo_slug}/pulls/${pr_number}/reviews" \
		--paginate \
		--jq '[.[] | select(.state == "CHANGES_REQUESTED" or ((.body // "") | length) > 30)
			| {author: (.user.login // "unknown"), state: .state,
			   body: (.body // ""), url: (.html_url // "")}]' \
		2>/dev/null) || reviews_json="[]"
	[[ -n "$reviews_json" ]] || reviews_json="[]"

	# --- Fetch inline review comments (file:line citations) ---
	local inline_json
	inline_json=$(gh api "repos/${repo_slug}/pulls/${pr_number}/comments" \
		--paginate \
		--jq '[.[] | {author: (.user.login // "unknown"),
			path: (.path // ""),
			line: (.line // .original_line // 0),
			body: (.body // ""), url: (.html_url // "")}]' \
		2>/dev/null) || inline_json="[]"
	[[ -n "$inline_json" ]] || inline_json="[]"

	# --- Build the Review Feedback markdown section ---
	local feedback_section
	feedback_section=$(_build_review_feedback_section \
		"$pr_number" "$repo_slug" "$reviews_json" "$inline_json") || feedback_section=""
	if [[ -z "$feedback_section" ]]; then
		echo "[pulse-wrapper] _dispatch_pr_fix_worker: PR #${pr_number} in ${repo_slug} has CHANGES_REQUESTED but no substantive review content — leaving PR open without routing (t2093)" >>"$LOGFILE"
		return 0
	fi

	# --- Append to linked issue body (marker-guarded for idempotency) ---
	# t2383 Fix 5: fail-safe — skip body edit when issue fetch fails to prevent
	# clobbering the issue body with only the routed-feedback section.
	local current_body review_fetch_rc
	review_fetch_rc=0
	current_body=$(gh issue view "$linked_issue" --repo "$repo_slug" \
		--json body --jq '.body // ""' 2>/dev/null) || review_fetch_rc=$?
	if [[ $review_fetch_rc -ne 0 ]]; then
		echo "[pulse-wrapper] _dispatch_pr_fix_worker: failed to fetch issue #${linked_issue} body (exit ${review_fetch_rc}) — skipping body edit to prevent data loss (t2383)" >>"$LOGFILE"
		return 0
	fi

	local marker="<!-- t2093:review-feedback:PR${pr_number} -->"
	local body_updated="false"
	if printf '%s' "$current_body" | grep -qF "$marker"; then
		echo "[pulse-wrapper] _dispatch_pr_fix_worker: issue #${linked_issue} in ${repo_slug} already has routed feedback marker for PR #${pr_number} — skipping body update (t2093)" >>"$LOGFILE"
		body_updated="true"
	else
		local new_body
		new_body="${current_body}

${marker}
${feedback_section}"
		if gh issue edit "$linked_issue" --repo "$repo_slug" \
			--body "$new_body" >/dev/null 2>&1; then
			body_updated="true"
		else
			echo "[pulse-wrapper] _dispatch_pr_fix_worker: failed to update issue #${linked_issue} body in ${repo_slug} — aborting routing for PR #${pr_number} (t2093)" >>"$LOGFILE"
			return 1
		fi
	fi

	# --- Transition issue status to `available` so it re-enters the
	# dispatch queue. set_issue_status atomically clears queued/in-progress/
	# in-review/claimed and adds status:available. Pass-through flag adds
	# the source:review-feedback marker. ---
	if declare -F set_issue_status >/dev/null 2>&1; then
		set_issue_status "$linked_issue" "$repo_slug" "available" \
			--add-label "source:review-feedback" >/dev/null 2>&1 || true
	else
		# Fallback for standalone tests / degraded environments: best-effort
		# direct label ops. set_issue_status is always present in real
		# pulse-wrapper.sh runs because shared-constants.sh is sourced at
		# bootstrap — see the include chain in pulse-wrapper.sh.
		gh issue edit "$linked_issue" --repo "$repo_slug" \
			--add-label "status:available" \
			--add-label "source:review-feedback" \
			--remove-label "status:queued" \
			--remove-label "status:in-progress" \
			--remove-label "status:in-review" \
			--remove-label "status:claimed" \
			>/dev/null 2>&1 || true
	fi

	# --- Close the stuck PR with explanatory comment ---
	local close_comment
	close_comment="## Review feedback routed to linked issue #${linked_issue} (t2093)

This worker-authored PR had \`reviewDecision=CHANGES_REQUESTED\`. Rather than let it sit
indefinitely (no human owns worker PRs and the dispatch-dedup guard treats an open worker
PR as an active claim), the deterministic merge pass has:

1. Extracted the review feedback (top-level reviews + file:line inline comments) and
   appended it to the linked issue body as a \"Review Feedback\" section.
2. Closed this PR so the dispatch queue can re-pick the linked issue.
3. Transitioned issue #${linked_issue} to \`status:available\` and tagged it
   \`source:review-feedback\` so the next pulse cycle dispatches a fresh worker with
   the feedback in its prompt.

The next worker will see the updated issue body, address the review findings, and
open a fresh PR against issue #${linked_issue}.

_Closed by deterministic merge pass (pulse-merge.sh, t2093)._"

	gh pr close "$pr_number" --repo "$repo_slug" \
		--comment "$close_comment" >/dev/null 2>&1 || true

	# Mark the PR as routed so any racing merge-pass re-read (via cached
	# listing) skips re-processing. This is belt-and-suspenders — closed
	# PRs are already excluded from the merge cycle's open-PR query.
	gh pr edit "$pr_number" --repo "$repo_slug" \
		--add-label "review-routed-to-issue" >/dev/null 2>&1 || true

	echo "[pulse-wrapper] _dispatch_pr_fix_worker: routed review feedback from PR #${pr_number} to issue #${linked_issue} in ${repo_slug} (body_updated=${body_updated}, t2093)" >>"$LOGFILE"
	return 0
}
