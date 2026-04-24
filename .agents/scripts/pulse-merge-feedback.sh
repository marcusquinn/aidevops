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
#   - _append_feedback_to_issue           (GH#20057, shared helper)
#   - _transition_issue_for_redispatch    (GH#20057, shared helper)
#   - _close_and_label_feedback_pr        (GH#20057, shared helper)
#   - _build_ci_feedback_section          (GH#20057, extracted builder)
#   - _dispatch_ci_fix_worker             (t2093 follow-up)
#   - _build_conflict_feedback_section    (t2426, extracted builder)
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
# Append a feedback section to a linked issue body, guarded by a marker
# comment for idempotency and with a t2383 fail-safe against body
# clobbering when the issue fetch fails.
#
# Shared by _dispatch_ci_fix_worker, _dispatch_conflict_fix_worker, and
# _dispatch_pr_fix_worker.
#
# Args:
#   $1 - linked_issue  (issue number)
#   $2 - repo_slug     (owner/repo)
#   $3 - marker        (HTML comment marker string)
#   $4 - feedback_section (markdown to append)
#   $5 - caller        (calling function name, for log messages)
#
# Returns: 0 on success or skip (already present), 1 on failure.
#######################################
_append_feedback_to_issue() {
	local linked_issue="$1"
	local repo_slug="$2"
	local marker="$3"
	local feedback_section="$4"
	local caller="$5"

	# t2383 Fix 5: fail-safe — skip body edit when issue fetch fails to
	# prevent clobbering the issue body with only the routed-feedback section.
	local current_body fetch_rc
	fetch_rc=0
	current_body=$(gh issue view "$linked_issue" --repo "$repo_slug" \
		--json body --jq '.body // ""' 2>/dev/null) || fetch_rc=$?
	if [[ $fetch_rc -ne 0 ]]; then
		echo "[pulse-wrapper] ${caller}: failed to fetch issue #${linked_issue} body (exit ${fetch_rc}) — skipping body edit to prevent data loss (t2383)" >>"$LOGFILE"
		return 1
	fi

	if printf '%s' "$current_body" | grep -qF "$marker"; then
		# Keep the "routed feedback marker" phrase stable for operator log
		# greps and regression tests (GH#20057): the pre-split dispatch
		# functions all logged a variant of "already has … feedback …".
		echo "[pulse-wrapper] ${caller}: issue #${linked_issue} already has routed feedback marker for this PR — skipping" >>"$LOGFILE"
		return 0
	fi

	local new_body="${current_body}

${marker}
${feedback_section}"
	gh issue edit "$linked_issue" --repo "$repo_slug" \
		--body "$new_body" >/dev/null 2>&1 || {
		echo "[pulse-wrapper] ${caller}: failed to update issue #${linked_issue} body — aborting" >>"$LOGFILE"
		return 1
	}
	return 0
}

#######################################
# Transition a linked issue to status:available and add a source label
# so the dispatch queue can re-pick the work.
#
# Uses set_issue_status when available (atomically clears other status
# labels), falls back to direct gh label ops in degraded environments.
#
# Args:
#   $1 - linked_issue  (issue number)
#   $2 - repo_slug     (owner/repo)
#   $3 - source_label  (e.g. "source:ci-feedback")
#######################################
_transition_issue_for_redispatch() {
	local linked_issue="$1"
	local repo_slug="$2"
	local source_label="$3"

	if declare -F set_issue_status >/dev/null 2>&1; then
		set_issue_status "$linked_issue" "$repo_slug" "available" \
			--add-label "$source_label" >/dev/null 2>&1 || true
	else
		gh issue edit "$linked_issue" --repo "$repo_slug" \
			--add-label "status:available" --add-label "$source_label" \
			--remove-label "status:queued" --remove-label "status:in-progress" \
			--remove-label "status:in-review" --remove-label "status:claimed" \
			>/dev/null 2>&1 || true
	fi
	return 0
}

#######################################
# Close a feedback-routed PR with an explanatory comment and apply an
# idempotency label.
#
# Args:
#   $1 - pr_number
#   $2 - repo_slug
#   $3 - close_comment  (markdown body for the close comment)
#   $4 - label          (e.g. "ci-feedback-routed")
#######################################
_close_and_label_feedback_pr() {
	local pr_number="$1"
	local repo_slug="$2"
	local close_comment="$3"
	local label="$4"

	gh pr close "$pr_number" --repo "$repo_slug" \
		--comment "$close_comment" >/dev/null 2>&1 || true
	gh pr edit "$pr_number" --repo "$repo_slug" \
		--add-label "$label" >/dev/null 2>&1 || true
	return 0
}

#######################################
# Build the markdown "CI Failure Feedback" section for routing to a
# linked issue.
#
# Args:
#   $1 - pr_number
#   $2 - failing_checks  (markdown list of failing check names/URLs)
#
# Output: markdown section on stdout.
#######################################
_build_ci_feedback_section() {
	local pr_number="$1"
	local failing_checks="$2"

	cat <<-EOF
		## CI Failure Feedback (from PR #${pr_number})

		The previous worker's PR #${pr_number} had failing required CI checks. The PR has been
		closed and this issue re-queued for dispatch. The next worker should address these failures.

		### Failing checks

		${failing_checks}

		### Worker guidance

		1. Check out a fresh branch from \`origin/main\` (do NOT reuse the old branch)
		2. Read the failing check URLs above for specific error messages
		3. Fix the issues in the code, not in the CI config
		4. Ensure all checks pass locally before pushing

		_Routed by deterministic merge pass (pulse-merge.sh)._
	EOF
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
	feedback_section=$(_build_ci_feedback_section "$pr_number" "$failing_checks")

	# Append to issue body (marker-guarded, t2383 fail-safe)
	local marker="<!-- ci-feedback:PR${pr_number} -->"
	_append_feedback_to_issue "$linked_issue" "$repo_slug" "$marker" \
		"$feedback_section" "_dispatch_ci_fix_worker" || return 0

	# Transition issue to available for re-dispatch
	_transition_issue_for_redispatch "$linked_issue" "$repo_slug" "source:ci-feedback"

	# Close the PR with feedback summary
	_close_and_label_feedback_pr "$pr_number" "$repo_slug" \
		"## CI failure feedback routed to issue #${linked_issue}

This worker PR had failing required CI checks. The failure details have been appended
to the linked issue body so the next worker can address them.

Failing checks:
${failing_checks}

_Closed by deterministic merge pass (pulse-merge.sh)._" \
		"ci-feedback-routed"

	echo "[pulse-wrapper] _dispatch_ci_fix_worker: routed CI failure feedback from PR #${pr_number} to issue #${linked_issue} in ${repo_slug}" >>"$LOGFILE"
	return 0
}

#######################################
# Build the conflict-feedback Markdown section for a closed-conflict PR.
#
# Produces the "## Merge Conflict Feedback" block appended to the linked
# issue body. Leads with cherry-pick-first guidance (t2426) — the prior
# worker's commit is usually correct-but-stale, so cherry-picking onto a
# fresh branch off current default branch is ~10x cheaper than rewriting.
#
# Scope-leak heuristic (t2802): if the prior PR touched more files than a
# focused fix should, that's a signal the BRANCH BASE was wrong, not that
# the semantic conflict is real. Rebuilding from the issue body is then
# cheaper than cherry-picking a scope-leaked branch. Canonical failure:
# awardsapp#2716 / PR #2733 (100 files for a 2-line fix). Successive
# workers burned opus tokens trying to cherry-pick the monster.
#
# Extracted from _dispatch_conflict_fix_worker to keep that function under
# the 100-line threshold (function-complexity gate).
#
# Args: $1=pr_number, $2=pr_title, $3=pr_files, $4=pr_head_sha,
#       $5=default_branch (e.g. "main", "develop"),
#       $6=pr_file_count (integer, may be empty)
# Stdout: the rendered section
#######################################
_build_conflict_feedback_section() {
	local pr_number="$1"
	local pr_title="$2"
	local pr_files="$3"
	local pr_head_sha="$4"
	local default_branch="${5:-main}"
	local pr_file_count="${6:-}"

	# Scope-leak detection (t2802). If prior PR touched >20 files, the
	# base was probably wrong (canonical HEAD stale). Cherry-picking a
	# scope-leaked branch is expensive and usually fails the same way
	# the first attempt did. Surface the signal upfront so the worker
	# rebuilds from the issue body instead of chasing a ghost diff.
	#
	# Build as plain quoted string (not heredoc-in-$()) so bash 3.2 accepts it.
	local scope_leak_warning=""
	if [[ -n "$pr_file_count" ]] && [[ "$pr_file_count" =~ ^[0-9]+$ ]] && ((pr_file_count > 20)); then
		scope_leak_warning="> ⚠ **Scope-leak signal**: the prior PR touched **${pr_file_count} files**. For most
> conflict-feedback loops the touch-count should be 1-5. A high count usually means
> the prior worker's branch was created off a stale canonical HEAD (not \`origin/${default_branch}\`),
> so the diff = \"everything ${default_branch} has that the stale base doesn't\" + the actual fix.
>
> **If the file list below looks unrelated to the original issue scope, skip the
> cherry-pick entirely** and rebuild from the issue body onto a fresh branch explicitly
> based on \`origin/${default_branch}\`. Cherry-picking a scope-leaked branch will fail
> the same way — that is why the prior attempt was closed.
>
> Framework fix in-flight: t2802 makes \`worktree-helper.sh add\` base new branches
> on \`origin/<default>\` explicitly instead of inheriting canonical HEAD."
	fi

	# Build scope-warning block separately to avoid interpolating empty lines.
	local scope_block=""
	if [[ -n "$scope_leak_warning" ]]; then
		scope_block=$'\n'"${scope_leak_warning}"$'\n'
	fi

	cat <<-EOF
		## Merge Conflict Feedback (from PR #${pr_number})

		The previous worker's PR #${pr_number} (\`${pr_title}\`) developed merge conflicts with
		\`${default_branch}\` that could not be resolved by \`gh pr update-branch\` (server-side fast-forward).
		The conflicts are semantic — the same files were modified on both branches${pr_file_count:+ (${pr_file_count} files touched)}.${scope_block}
		### Files in the conflicting PR

		\`\`\`
		${pr_files}
		\`\`\`

		### Worker guidance

		The prior PR's head commit is \`${pr_head_sha:-<lookup via gh pr view ${pr_number} --json headRefOid>}\`. Choose the cheapest path that works:

		1. **Cherry-pick onto a fresh branch off current \`origin/${default_branch}\`** (~10x cheaper than rewriting, works when the prior implementation was correct-but-stale):

		   \`\`\`bash
		   git fetch origin pull/${pr_number}/head:recovered-${pr_number}
		   # Explicit base on origin/${default_branch} — NOT canonical HEAD (t2802).
		   git worktree add -b fresh-branch ../fresh-worktree origin/${default_branch}
		   cd ../fresh-worktree
		   git cherry-pick ${pr_head_sha:-<head-sha>}
		   # run tests — if clean, proceed to PR
		   \`\`\`

		2. **If cherry-pick surfaces conflicts**, resolve them. The conflict surface IS the semantic overlap between the two branches — resolve those specific hunks rather than rewriting untouched logic.

		3. **If the scope-leak warning above fired** (prior PR >20 files but the issue describes a focused fix), **skip cherry-pick entirely** and rebuild from scratch using the issue body as the spec. Do NOT try to cherry-pick-then-drop-files — too error-prone. A clean rewrite from the 2-line spec is cheaper than surgery on a 100-file branch.

		4. **Only rewrite from scratch (scope-OK case)** if the prior approach was rejected in review. Check PR #${pr_number}'s review comments for \`CHANGES_REQUESTED\` or rejection keywords before assuming the approach was wrong.

		Do NOT reuse the old PR's branch directly — always cherry-pick onto a fresh branch off current \`origin/${default_branch}\`.

		_Routed by deterministic merge pass (pulse-merge.sh)._
	EOF
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

	# File count for scope-leak heuristic (t2802). Rely on the already-fetched
	# file list rather than a second API call — a line count of the joined
	# output matches the files array length when pr_files fetched cleanly.
	local pr_file_count=""
	if [[ -n "$pr_files" ]] && [[ "$pr_files" != "(could not fetch)" ]]; then
		pr_file_count=$(printf '%s\n' "$pr_files" | grep -c '^.' || true)
	fi

	# Get the closed PR's head commit SHA (t2426) — reachable for >=30 days after close
	# and lets the next worker cherry-pick instead of rewriting from scratch.
	local pr_head_sha
	pr_head_sha=$(gh pr view "$pr_number" --repo "$repo_slug" \
		--json headRefOid --jq '.headRefOid' 2>/dev/null) || pr_head_sha=""

	# Default branch for the repo. Use gh for the authoritative answer (the
	# pulse may run from a repo path that differs from repo_slug). Fall back
	# to "main" if detection fails — matches pre-t2802 behaviour.
	local default_branch
	default_branch=$(gh repo view "$repo_slug" \
		--json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null) || default_branch=""
	[[ -n "$default_branch" ]] || default_branch="main"

	local feedback_section
	feedback_section=$(_build_conflict_feedback_section \
		"$pr_number" "$pr_title" "$pr_files" "$pr_head_sha" \
		"$default_branch" "$pr_file_count")

	# Append to issue body (marker-guarded, t2383 fail-safe)
	local marker="<!-- conflict-feedback:PR${pr_number} -->"
	_append_feedback_to_issue "$linked_issue" "$repo_slug" "$marker" \
		"$feedback_section" "_dispatch_conflict_fix_worker" || return 0

	# Transition issue to available for re-dispatch
	_transition_issue_for_redispatch "$linked_issue" "$repo_slug" "source:conflict-feedback"

	# Close the PR with conflict context
	_close_and_label_feedback_pr "$pr_number" "$repo_slug" \
		"## Merge conflict feedback routed to issue #${linked_issue}

This worker PR had semantic merge conflicts with \`${default_branch}\` that \`update-branch\` could not resolve. The conflict context and file list have been appended to the linked issue body so the next worker can re-implement on top of current \`${default_branch}\`.

_Closed by deterministic merge pass (pulse-merge.sh)._" \
		"conflict-feedback-routed"

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

	# --- Append to linked issue body (marker-guarded, t2383 fail-safe) ---
	local marker="<!-- t2093:review-feedback:PR${pr_number} -->"
	_append_feedback_to_issue "$linked_issue" "$repo_slug" "$marker" \
		"$feedback_section" "_dispatch_pr_fix_worker" || return 0

	# --- Transition issue status to available for re-dispatch ---
	_transition_issue_for_redispatch "$linked_issue" "$repo_slug" "source:review-feedback"

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

	# Mark the PR as routed so any racing merge-pass re-read (via cached
	# listing) skips re-processing. This is belt-and-suspenders — closed
	# PRs are already excluded from the merge cycle's open-PR query.
	_close_and_label_feedback_pr "$pr_number" "$repo_slug" \
		"$close_comment" "review-routed-to-issue"

	echo "[pulse-wrapper] _dispatch_pr_fix_worker: routed review feedback from PR #${pr_number} to issue #${linked_issue} in ${repo_slug} (t2093)" >>"$LOGFILE"
	return 0
}
