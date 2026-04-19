#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-merge.sh — Co-extracted pr-gates + merge clusters (2-cycle) — PR gate checks (external contributor, permission, workflow scope) and merge-ready PR processing + linked-issue extraction.
#
# Extracted from pulse-wrapper.sh in Phase 4 of the phased decomposition
# (parent: GH#18356, plan: todo/plans/pulse-wrapper-decomposition.md §6).
#
# NOTE: This module contains TWO clusters (pr-gates + merge) that form a
# dependency cycle. They must be co-located in the same module so bash's
# lazy function name resolution can see both sides of the cycle after a
# single source. Splitting them would require defining stubs or ordering
# sources against call graphs — the plan chose co-extraction as simpler.
#
# In GH#19836 the module was further trimmed by extracting two downstream
# clusters that are called after the gate checks fire. They are sourced
# by pulse-wrapper.sh AFTER pulse-merge.sh so they can use shared merge
# helpers such as _extract_linked_issue, while Bash lazy resolution keeps
# the runtime cross-module calls safe. The dependency is one-way only
# (downstream → core); merge-core/pr-gates do not require the downstream
# modules at source time:
#   - pulse-merge-conflict.sh — conflict handling, interactive handover,
#     carry-forward diff, rebase nudges
#   - pulse-merge-feedback.sh — CI/conflict/review feedback routing to
#     linked issues with PR close
# Example cross-module call: _check_pr_merge_gates (merge-core) →
# _dispatch_pr_fix_worker (feedback) is resolved at invocation time.
#
# This module is sourced by pulse-wrapper.sh. It MUST NOT be executed
# directly — it relies on the orchestrator having sourced:
#   shared-constants.sh
#   worker-lifecycle-common.sh
# and having defined all PULSE_* configuration constants in the bootstrap
# section.
#
# Functions in this module (in source order — pr-gates cluster first, then merge):
#   - check_external_contributor_pr
#   - _external_pr_has_linked_issue
#   - _external_pr_linked_issue_crypto_approved
#   - check_permission_failure_pr
#   - approve_collaborator_pr
#   - check_pr_modifies_workflows
#   - check_gh_workflow_scope
#   - check_workflow_merge_guard
#   - merge_ready_prs_all_repos
#   - _merge_ready_prs_for_repo
#   - _attempt_pr_update_branch
#   - _resolve_pr_mergeable_status
#   - _pulse_merge_dismiss_coderabbit_nits      (t2179)
#   - _pr_required_checks_pass
#   - _check_pr_merge_gates
#   - _handle_post_merge_actions
#   - _process_single_ready_pr
#   - _is_collaborator_author
#   - _extract_linked_issue
#   - _extract_merge_summary
#
# This was originally a pure move from pulse-wrapper.sh. Later additions
# (rebase nudges GH#18650/GH#18815, review-feedback routing t2093, the
# GH#19836 split) preserve that call site.

# Include guard — prevent double-sourcing.
[[ -n "${_PULSE_MERGE_LOADED:-}" ]] && return 0
_PULSE_MERGE_LOADED=1

#######################################
# Check and flag external-contributor PRs (t1391)
#
# Deterministic idempotency guard for the external-contributor comment.
# Moved from pulse.md inline bash to a shell function because the LLM
# kept getting the fail-closed logic wrong (4 prior fix attempts:
# PRs #2794, #2796, #2801, #2803 — all in pulse.md prompt text).
#
# This is exactly the kind of logic that belongs in the harness, not
# the prompt: it has one correct answer regardless of context.
#
# Arguments:
#   $1 - PR number
#   $2 - repo slug (owner/repo)
#   $3 - PR author login
#
# Exit codes:
#   0 - already flagged (label or comment exists) — no action needed
#   1 - not yet flagged AND API calls succeeded — caller should post
#   2 - API error (fail closed) — caller must skip, next pulse retries
#
# Side effects when exit=1 (caller invokes with --post):
#   Posts the external-contributor comment and adds the label.
#######################################
check_external_contributor_pr() {
	local pr_number="$1"
	local repo_slug="$2"
	local pr_author="$3"
	local do_post="${4:-}"

	# Validate arguments
	if [[ -z "$pr_number" || -z "$repo_slug" || -z "$pr_author" ]]; then
		echo "[pulse-wrapper] check_external_contributor_pr: missing arguments" >>"$LOGFILE"
		return 2
	fi

	# Step 1: Check for existing label (capture exit code separately from output)
	local label_output
	label_output=$(gh pr view "$pr_number" --repo "$repo_slug" --json labels --jq '.labels[].name')
	local label_exit=$?

	local has_label=false
	if [[ $label_exit -eq 0 ]] && echo "$label_output" | grep -q '^external-contributor$'; then
		has_label=true
	fi

	# Step 2: Check for existing comment
	local comment_output
	comment_output=$(gh pr view "$pr_number" --repo "$repo_slug" --json comments --jq '.comments[].body')
	local comment_exit=$?

	local has_comment=false
	if [[ $comment_exit -eq 0 ]] && echo "$comment_output" | grep -qiF 'external contributor'; then
		has_comment=true
	fi

	# Step 3: Decide action based on results
	if [[ $label_exit -ne 0 || $comment_exit -ne 0 ]]; then
		# API error on label or comment check — fail closed, skip posting entirely.
		# The next pulse cycle will retry. Never post when we can't confirm absence.
		echo "[pulse-wrapper] check_external_contributor_pr: API error (label_exit=$label_exit, comment_exit=$comment_exit) for PR #$pr_number in $repo_slug — skipping (fail closed)" >>"$LOGFILE"
		return 2
	fi

	if [[ "$has_label" == "true" || "$has_comment" == "true" ]]; then
		# Already flagged. Re-add label if missing (comment exists but label doesn't).
		if [[ "$has_label" == "false" ]]; then
			gh api --silent "repos/${repo_slug}/issues/${pr_number}/labels" \
				-X POST -f 'labels[]=external-contributor' || true
		fi
		return 0
	fi

	# Both API calls succeeded AND neither label nor comment exists.
	if [[ "$do_post" == "--post" ]]; then
		# Safe to post — this is the only code path that creates a comment.
			gh_pr_comment "$pr_number" --repo "$repo_slug" \
			--body "This PR is from an external contributor (@${pr_author}). Auto-merge is disabled for external PRs — a maintainer must review and approve manually.

External contributor PRs have two requirements before they can merge:
1. A linked issue (\`Resolves #NNN\` in the PR body, or \`GH#NNN:\` prefix in the title)
2. Cryptographic approval on that linked issue (\`sudo aidevops approve issue NNN\`)

---
**To approve or decline**, comment on this PR:
- \`approved\` — removes the review gate and allows merge (CI permitting)
- \`declined: <reason>\` — closes this PR (include your reason after the colon)" &&
			gh api --silent "repos/${repo_slug}/issues/${pr_number}/labels" \
				-X POST -f 'labels[]=external-contributor' \
				-f 'labels[]=needs-maintainer-review' || true
		echo "[pulse-wrapper] check_external_contributor_pr: flagged PR #$pr_number in $repo_slug as external contributor (@$pr_author)" >>"$LOGFILE"

		# Post a second comment if no linked issue found (t1958)
		local linked_for_check
		linked_for_check=$(_extract_linked_issue "$pr_number" "$repo_slug" 2>/dev/null) || linked_for_check=""
		if [[ -z "$linked_for_check" ]]; then
		gh_pr_comment "$pr_number" --repo "$repo_slug" \
				--body "**Missing linked issue.** This PR has no linked issue. External contributor PRs require a linked issue before they can be considered for merge. Add \`Resolves #NNN\` to the PR body (or use \`GH#NNN:\` in the title), then ensure that issue has been cryptographically approved by a maintainer (\`sudo aidevops approve issue NNN\`)." || true
			echo "[pulse-wrapper] check_external_contributor_pr: PR #$pr_number in $repo_slug has no linked issue — posted missing-linked-issue comment" >>"$LOGFILE"
		fi
	fi
	return 1
}

#######################################
# Check if an external-contributor PR has a linked issue (t1958).
#
# Arguments:
#   $1 - PR number
#   $2 - repo slug (owner/repo)
# Returns: 0 if linked issue found, 1 if not
#######################################
_external_pr_has_linked_issue() {
	local pr_number="$1"
	local repo_slug="$2"
	local linked
	linked=$(_extract_linked_issue "$pr_number" "$repo_slug" 2>/dev/null) || linked=""
	[[ -n "$linked" ]]
	return $?
}

#######################################
# Check if an external-contributor PR's linked issue has crypto approval (t1958).
#
# Unlike issue_has_required_approval() (which gates on ever-NMR history),
# this function requires approval unconditionally for all external PRs.
#
# Arguments:
#   $1 - PR number
#   $2 - repo slug (owner/repo)
# Returns: 0 if approved, 1 if not approved or no linked issue
#######################################
_external_pr_linked_issue_crypto_approved() {
	local pr_number="$1"
	local repo_slug="$2"
	local linked
	linked=$(_extract_linked_issue "$pr_number" "$repo_slug" 2>/dev/null) || linked=""
	[[ -z "$linked" ]] && return 1
	local approval_helper="${AGENTS_DIR:-$HOME/.aidevops/agents}/scripts/approval-helper.sh"
	[[ ! -f "$approval_helper" ]] && return 1
	local result
	result=$(bash "$approval_helper" verify "$linked" "$repo_slug" 2>/dev/null) || result=""
	[[ "$result" == "VERIFIED" ]]
	return $?
}

#######################################
# Check and post permission-failure comment on a PR (t1391)
#
# Companion to check_external_contributor_pr() for the case where the
# collaborator permission API itself fails (403, 429, 5xx, network error).
# Posts a distinct "Permission check failed" comment so a maintainer
# knows to review manually. Idempotent — checks for existing comment
# before posting, fails closed on API errors.
#
# Arguments:
#   $1 - PR number
#   $2 - repo slug (owner/repo)
#   $3 - PR author login
#   $4 - HTTP status code from the failed permission check
#
# Exit codes:
#   0 - comment already exists or was just posted
#   2 - API error checking for existing comment (fail closed, skip)
#######################################
check_permission_failure_pr() {
	local pr_number="$1"
	local repo_slug="$2"
	local pr_author="$3"
	local http_status="${4:-unknown}"

	if [[ -z "$pr_number" || -z "$repo_slug" || -z "$pr_author" ]]; then
		echo "[pulse-wrapper] check_permission_failure_pr: missing arguments" >>"$LOGFILE"
		return 2
	fi

	# Check for existing permission-failure comment (fail closed on API error)
	local perm_comments
	perm_comments=$(gh pr view "$pr_number" --repo "$repo_slug" --json comments --jq '.comments[].body')
	local perm_exit=$?

	if [[ $perm_exit -ne 0 ]]; then
		echo "[pulse-wrapper] check_permission_failure_pr: API error (exit=$perm_exit) for PR #$pr_number in $repo_slug — skipping (fail closed)" >>"$LOGFILE"
		return 2
	fi

	if echo "$perm_comments" | grep -qF 'Permission check failed'; then
		# Already posted — nothing to do
		return 0
	fi

	# Safe to post — no existing comment and API call succeeded
	gh_pr_comment "$pr_number" --repo "$repo_slug" \
		--body "Permission check failed for this PR (HTTP ${http_status} from collaborator permission API). Unable to determine if @${pr_author} is a maintainer or external contributor. **A maintainer must review and merge this PR manually.** This is a fail-closed safety measure — the pulse will not auto-merge until the permission API succeeds." || true

	echo "[pulse-wrapper] check_permission_failure_pr: posted permission-failure comment on PR #$pr_number in $repo_slug (HTTP $http_status)" >>"$LOGFILE"
	return 0
}

#######################################
# Auto-approve a collaborator's PR before merging (GH#10522, t1691)
#
# Branch protection requires required_approving_review_count=1.
# The pulse runs with the repo admin's token, which can approve PRs.
# This function approves the PR so that gh pr merge succeeds.
#
# SAFETY: Only call this AFTER the external contributor gate has
# confirmed the PR author is a collaborator (admin/maintain/write).
# NEVER call this for external contributor PRs.
#
# Idempotent — if the PR already has an approving review from the
# current user, this is a no-op (GitHub ignores duplicate approvals).
#
# Arguments:
#   $1 - PR number
#   $2 - repo slug (owner/repo)
#   $3 - PR author login (for logging only)
#
# Exit codes:
#   0 - PR approved (or already approved)
#   1 - approval failed (caller should skip merge this cycle)
#   2 - missing arguments
#######################################
approve_collaborator_pr() {
	local pr_number="$1"
	local repo_slug="$2"
	local pr_author="${3:-unknown}"

	if [[ -z "$pr_number" || -z "$repo_slug" ]]; then
		echo "[pulse-wrapper] approve_collaborator_pr: missing arguments" >>"$LOGFILE"
		return 2
	fi

	# Check if we already approved (avoid noisy duplicate approvals in the timeline)
	local current_user
	current_user=$(gh api user --jq '.login' 2>/dev/null || echo "")

	if [[ -n "$current_user" ]]; then
		# Skip self-approval — GitHub rejects it and the failed review state
		# blocks subsequent --admin merge. Admin bypass works without approval
		# when the PR author is the authenticated user (repo admin).
		if [[ "$current_user" == "$pr_author" ]]; then
			echo "[pulse-wrapper] approve_collaborator_pr: PR #$pr_number is self-authored ($current_user) — skipping approval (--admin handles it)" >>"$LOGFILE"
			return 0
		fi

		# Guard: only collaborators (write/maintain/admin) may approve.
		# Non-collaborator approvals are accepted by GitHub on public repos
		# but don't count toward branch protection — they just create noise.
		if ! _is_collaborator_author "$current_user" "$repo_slug"; then
			echo "[pulse-wrapper] approve_collaborator_pr: current user ($current_user) lacks write access to $repo_slug — skipping approval" >>"$LOGFILE"
			return 0
		fi

		local existing_approval
		existing_approval=$(gh api "repos/${repo_slug}/pulls/${pr_number}/reviews" \
			--jq "[.[] | select(.user.login == \"${current_user}\" and .state == \"APPROVED\")] | length" 2>/dev/null || echo "0")

		if [[ "$existing_approval" -gt 0 ]]; then
			echo "[pulse-wrapper] approve_collaborator_pr: PR #$pr_number in $repo_slug already approved by $current_user — skipping" >>"$LOGFILE"
			return 0
		fi
	fi

	# Approve the PR
	local approve_output
	approve_output=$(gh pr review "$pr_number" --repo "$repo_slug" --approve --body "Auto-approved by pulse — collaborator PR (author: @${pr_author}). All pre-merge checks passed." 2>&1)
	local approve_exit=$?

	if [[ $approve_exit -eq 0 ]]; then
		echo "[pulse-wrapper] approve_collaborator_pr: approved PR #$pr_number in $repo_slug (author: $pr_author)" >>"$LOGFILE"
		return 0
	fi

	echo "[pulse-wrapper] approve_collaborator_pr: failed to approve PR #$pr_number in $repo_slug — $approve_output" >>"$LOGFILE"
	return 1
}

#######################################
# Check if a PR modifies GitHub Actions workflow files (t3934)
#
# PRs that modify .github/workflows/ files require the `workflow` scope
# on the GitHub OAuth token. Without it, `gh pr merge` fails with:
#   "refusing to allow an OAuth App to create or update workflow ... without workflow scope"
#
# This function checks the PR's changed files for workflow modifications
# so the pulse can skip auto-merge and post a helpful comment instead of
# failing with a cryptic GraphQL error.
#
# Arguments:
#   $1 - PR number
#   $2 - repo slug (owner/repo)
#
# Exit codes:
#   0 - PR modifies workflow files
#   1 - PR does NOT modify workflow files
#   2 - API error (fail open — let merge attempt proceed)
#######################################
check_pr_modifies_workflows() {
	local pr_number="$1"
	local repo_slug="$2"

	if [[ -z "$pr_number" || -z "$repo_slug" ]]; then
		echo "[pulse-wrapper] check_pr_modifies_workflows: missing arguments" >>"$LOGFILE"
		return 2
	fi

	local files_output
	files_output=$(gh pr view "$pr_number" --repo "$repo_slug" --json files --jq '.files[].path')
	local files_exit=$?

	if [[ $files_exit -ne 0 ]]; then
		echo "[pulse-wrapper] check_pr_modifies_workflows: API error (exit=$files_exit) for PR #$pr_number in $repo_slug — failing open" >>"$LOGFILE"
		return 2
	fi

	if echo "$files_output" | grep -qE '^\.github/workflows/'; then
		echo "[pulse-wrapper] check_pr_modifies_workflows: PR #$pr_number in $repo_slug modifies workflow files" >>"$LOGFILE"
		return 0
	fi

	return 1
}

#######################################
# Check if the current GitHub token has the `workflow` scope (t3934)
#
# The `workflow` scope is required to merge PRs that modify
# .github/workflows/ files. This function checks the current
# token's scopes via `gh auth status`.
#
# Exit codes:
#   0 - token HAS workflow scope
#   1 - token does NOT have workflow scope
#   2 - unable to determine (fail open)
#######################################
check_gh_workflow_scope() {
	local auth_output
	auth_output=$(gh auth status 2>&1)
	local auth_exit=$?

	if [[ $auth_exit -ne 0 ]]; then
		echo "[pulse-wrapper] check_gh_workflow_scope: gh auth status failed (exit=$auth_exit) — failing open" >>"$LOGFILE"
		return 2
	fi

	if echo "$auth_output" | grep -q "'workflow'"; then
		return 0
	fi

	# Also check for the scope without quotes (format varies by gh version)
	if echo "$auth_output" | grep -qiE 'Token scopes:.*workflow'; then
		return 0
	fi

	echo "[pulse-wrapper] check_gh_workflow_scope: token lacks workflow scope" >>"$LOGFILE"
	return 1
}

#######################################
# Guard merge of PRs that modify workflow files (t3934)
#
# Combines check_pr_modifies_workflows() and check_gh_workflow_scope()
# into a single pre-merge guard. If the PR modifies workflow files and
# the token lacks the workflow scope, posts a comment explaining the
# issue and how to fix it. Idempotent — checks for existing comment.
#
# Arguments:
#   $1 - PR number
#   $2 - repo slug (owner/repo)
#
# Exit codes:
#   0 - safe to merge (no workflow files, or token has scope)
#   1 - blocked (workflow files + missing scope, comment posted)
#   2 - API error (fail open — let merge attempt proceed)
#######################################
check_workflow_merge_guard() {
	local pr_number="$1"
	local repo_slug="$2"

	if [[ -z "$pr_number" || -z "$repo_slug" ]]; then
		echo "[pulse-wrapper] check_workflow_merge_guard: missing arguments" >>"$LOGFILE"
		return 2
	fi

	# Step 1: Check if PR modifies workflow files
	check_pr_modifies_workflows "$pr_number" "$repo_slug"
	local wf_exit=$?

	if [[ $wf_exit -eq 1 ]]; then
		# No workflow files modified — safe to merge
		return 0
	fi

	if [[ $wf_exit -eq 2 ]]; then
		# API error — fail open, let merge attempt proceed
		return 2
	fi

	# Step 2: PR modifies workflow files — check token scope
	check_gh_workflow_scope
	local scope_exit=$?

	if [[ $scope_exit -eq 0 ]]; then
		# Token has workflow scope — safe to merge
		return 0
	fi

	if [[ $scope_exit -eq 2 ]]; then
		# Unable to determine — fail open
		return 2
	fi

	# Step 3: PR modifies workflows AND token lacks scope — check for existing comment
	local comments_output
	comments_output=$(gh pr view "$pr_number" --repo "$repo_slug" --json comments --jq '.comments[].body')
	local comments_exit=$?

	if [[ $comments_exit -ne 0 ]]; then
		echo "[pulse-wrapper] check_workflow_merge_guard: API error reading comments for PR #$pr_number — failing open" >>"$LOGFILE"
		return 2
	fi

	if echo "$comments_output" | grep -qF 'workflow scope'; then
		# Already commented — still blocked
		echo "[pulse-wrapper] check_workflow_merge_guard: PR #$pr_number already has workflow scope comment — skipping merge" >>"$LOGFILE"
		return 1
	fi

	# Post comment explaining the issue
	gh_pr_comment "$pr_number" --repo "$repo_slug" \
		--body "**Cannot auto-merge: workflow scope required** (GH#3934)

This PR modifies \`.github/workflows/\` files but the GitHub OAuth token used by the pulse lacks the \`workflow\` scope. GitHub requires this scope to merge PRs that modify workflow files.

**To fix:**
1. Run \`gh auth refresh -s workflow\` to add the \`workflow\` scope to your token
2. The next pulse cycle will merge this PR automatically

**Alternatively:** Merge manually via the GitHub UI." ||
		true

	# Add a label for visibility
	gh api --silent "repos/${repo_slug}/issues/${pr_number}/labels" \
		-X POST -f 'labels[]=needs-workflow-scope' || true

	echo "[pulse-wrapper] check_workflow_merge_guard: blocked PR #$pr_number in $repo_slug — workflow files + missing scope" >>"$LOGFILE"
	return 1
}

merge_ready_prs_all_repos() {
	if [[ -f "$STOP_FLAG" ]]; then
		echo "[pulse-wrapper] Deterministic merge pass skipped: stop flag present" >>"$LOGFILE"
		return 0
	fi

	if [[ ! -f "$REPOS_JSON" ]]; then
		echo "[pulse-wrapper] Deterministic merge pass skipped: repos.json not found" >>"$LOGFILE"
		return 0
	fi

	local total_merged=0
	local total_closed=0
	local total_failed=0

	while IFS='|' read -r repo_slug repo_path; do
		[[ -n "$repo_slug" ]] || continue

		local repo_merged=0
		local repo_closed=0
		local repo_failed=0

		_merge_ready_prs_for_repo "$repo_slug" repo_merged repo_closed repo_failed

		total_merged=$((total_merged + repo_merged))
		total_closed=$((total_closed + repo_closed))
		total_failed=$((total_failed + repo_failed))

		if [[ -f "$STOP_FLAG" ]]; then
			echo "[pulse-wrapper] Deterministic merge pass: stop flag appeared mid-run" >>"$LOGFILE"
			break
		fi
	done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | [.slug, .path] | join("|")' "$REPOS_JSON" 2>/dev/null)

	echo "[pulse-wrapper] Deterministic merge pass complete: merged=${total_merged}, closed_conflicting=${total_closed}, failed=${total_failed}" >>"$LOGFILE"
	# Write health counter deltas to a temp file (GH#18571, GH#15107).
	# run_stage_with_timeout backgrounds this function in a subshell, so
	# direct updates to _PULSE_HEALTH_* variables are lost on return.
	# The parent process reads this file after the stage completes.
	local _health_delta_file="${TMPDIR:-/tmp}/pulse-health-merge-$$.tmp"
	printf '%s %s\n' "$total_merged" "$total_closed" >"$_health_delta_file" || true
	return 0
}

#######################################
# Merge ready PRs for a single repo.
#
# Fetches the PR list for the repo, iterates, and delegates each PR
# to _process_single_ready_pr. Uses eval to return counts to caller
# (Bash 3.2 compat: no nameref).
#
# Args:
#   $1 - repo slug
#   $2 - nameref for merged count
#   $3 - nameref for closed count
#   $4 - nameref for failed count
#######################################
_merge_ready_prs_for_repo() {
	local repo_slug="$1"
	# Bash 3.2 compat: no nameref. Use eval to set caller variables.
	local _merged_var="$2"
	local _closed_var="$3"
	local _failed_var="$4"

	local merged=0
	local closed=0
	local failed=0

	# Fetch open PRs — lightweight call without statusCheckRollup (GH#15060 lesson)
	local pr_json pr_merge_err
	pr_merge_err=$(mktemp)
	pr_json=$(gh pr list --repo "$repo_slug" --state open \
		--json number,mergeable,reviewDecision,author,title \
		--limit "$PULSE_MERGE_BATCH_LIMIT" 2>"$pr_merge_err") || pr_json="[]"
	if [[ -z "$pr_json" || "$pr_json" == "null" ]]; then
		local _pr_merge_err_msg
		_pr_merge_err_msg=$(cat "$pr_merge_err" 2>/dev/null || echo "unknown error")
		echo "[pulse-wrapper] _process_merge_batch: gh pr list FAILED for ${repo_slug}: ${_pr_merge_err_msg}" >>"$LOGFILE"
		pr_json="[]"
	fi
	rm -f "$pr_merge_err"

	local pr_count
	pr_count=$(printf '%s' "$pr_json" | jq 'length' 2>/dev/null) || pr_count=0
	[[ "$pr_count" =~ ^[0-9]+$ ]] || pr_count=0

	if [[ "$pr_count" -eq 0 ]]; then
		eval "${_merged_var}=0; ${_closed_var}=0; ${_failed_var}=0"
		return 0
	fi

	# Process each PR — extract its JSON object and delegate to inner helper
	local i=0
	while [[ "$i" -lt "$pr_count" ]]; do
		[[ -f "$STOP_FLAG" ]] && break
		local pr_obj
		pr_obj=$(printf '%s' "$pr_json" | jq -c ".[$i]" 2>/dev/null)
		i=$((i + 1))
		[[ -n "$pr_obj" ]] || continue

		_process_single_ready_pr "$repo_slug" "$pr_obj"
		local _pr_rc=$?
		case "$_pr_rc" in
		0) merged=$((merged + 1)) ;;
		2) closed=$((closed + 1)) ;;
		3) failed=$((failed + 1)) ;;
		esac
	done

	eval "${_merged_var}=${merged}; ${_closed_var}=${closed}; ${_failed_var}=${failed}"
	return 0
}

#######################################
# Attempt to fast-forward the PR's branch to the latest base branch head
# via `gh pr update-branch`. GitHub's server-side merger will merge main
# into the branch when the changes don't semantically conflict; this
# salvages a large class of CONFLICTING PRs where the only issue is that
# main advanced while the worker was finishing or waiting (t2116).
#
# Returns 0 on success (branch now up to date, caller should re-fetch
# mergeable state), 1 on failure (true semantic conflict, caller should
# fall through to the close path).
#
# Rate-limit considerations: one `gh pr update-branch` call per CONFLICTING
# PR per merge cycle. No retry — the next pulse cycle will try again if
# appropriate.
#
# Args: $1=pr_number, $2=repo_slug
#######################################
_attempt_pr_update_branch() {
	local pr_number="$1"
	local repo_slug="$2"

	local _ub_output _ub_exit
	_ub_output=$(gh pr update-branch "$pr_number" --repo "$repo_slug" 2>&1)
	_ub_exit=$?

	if [[ $_ub_exit -eq 0 ]]; then
		echo "[pulse-wrapper] Merge pass: PR #${pr_number} in ${repo_slug} — update-branch succeeded (t2116)" >>"$LOGFILE"
		# Brief pause so GitHub recomputes mergeable state before the
		# caller re-fetches it.
		sleep 2
		return 0
	fi

	echo "[pulse-wrapper] Merge pass: PR #${pr_number} in ${repo_slug} — update-branch failed, falling through to close (t2116): ${_ub_output}" >>"$LOGFILE"
	return 1
}

#######################################
# Resolve PR mergeable status, retrying once for UNKNOWN state.
# Returns 0 if MERGEABLE, 1 if not (caller should skip this PR).
# Args: $1=pr_number, $2=repo_slug, $3=current_mergeable_state
#######################################
_resolve_pr_mergeable_status() {
	local pr_number="$1"
	local repo_slug="$2"
	local pr_mergeable="$3"

	if [[ "$pr_mergeable" == "UNKNOWN" ]]; then
		# Separate local declaration from assignment to preserve exit code (SC2181).
		local _retry_output _retry_exit
		_retry_output=$(gh pr view "$pr_number" --repo "$repo_slug" \
			--json mergeable --jq '.mergeable // ""')
		_retry_exit=$?
		[[ $_retry_exit -eq 0 && -n "$_retry_output" ]] && pr_mergeable="$_retry_output" || pr_mergeable="UNKNOWN"
		if [[ "$pr_mergeable" == "MERGEABLE" ]]; then
			echo "[pulse-wrapper] Merge pass: PR #${pr_number} in ${repo_slug} — mergeable resolved to MERGEABLE after retry" >>"$LOGFILE"
		else
			echo "[pulse-wrapper] Merge pass: skipping PR #${pr_number} in ${repo_slug} — mergeable=${pr_mergeable} (was UNKNOWN, still not MERGEABLE after retry)" >>"$LOGFILE"
			return 1
		fi
	fi
	if [[ "$pr_mergeable" != "MERGEABLE" ]]; then
		echo "[pulse-wrapper] Merge pass: skipping PR #${pr_number} in ${repo_slug} — mergeable=${pr_mergeable}" >>"$LOGFILE"
		return 1
	fi
	return 0
}

#######################################
# Auto-dismiss CodeRabbit-only CHANGES_REQUESTED reviews when the
# coderabbit-nits-ok PR label has been applied by a maintainer (t2179).
#
# Enumerates all CHANGES_REQUESTED reviews on the PR. If any reviewer is
# NOT coderabbitai[bot], returns 1 immediately — human reviewers are never
# auto-dismissed. Otherwise dismisses each CodeRabbit review via the GitHub
# reviews/dismissals API and returns 0.
#
# Returns: 0 if all CR reviews dismissed (or none existed)
#          1 if a non-CR human review is blocking dismissal
#
# Arguments: $1=pr_number, $2=repo_slug
#######################################
_pulse_merge_dismiss_coderabbit_nits() {
	local pr_number="$1"
	local repo_slug="$2"
	local reviews_json review_count has_human ids review_id

	# Fetch all CHANGES_REQUESTED reviews as id+login pairs.
	reviews_json=$(gh api "repos/${repo_slug}/pulls/${pr_number}/reviews" \
		--jq '[.[] | select(.state=="CHANGES_REQUESTED") | {id: .id, login: .user.login}]' \
		2>/dev/null) || reviews_json="[]"

	# No CHANGES_REQUESTED reviews — nothing to dismiss, safe to proceed.
	review_count=$(printf '%s' "$reviews_json" | jq 'length' 2>/dev/null) || review_count=0
	if [[ "$review_count" -eq 0 ]]; then
		return 0
	fi

	# If any CHANGES_REQUESTED reviewer is not coderabbitai[bot], bail immediately.
	# Human reviewers are never auto-dismissed regardless of the label.
	has_human=$(printf '%s' "$reviews_json" | \
		jq -r '[.[] | select(.login != "coderabbitai[bot]")] | length' 2>/dev/null) || has_human=0
	if [[ "$has_human" -gt 0 ]]; then
		return 1
	fi

	# All CHANGES_REQUESTED reviews are from coderabbitai[bot] — dismiss each.
	ids=$(printf '%s' "$reviews_json" | jq -r '.[].id' 2>/dev/null) || ids=""
	while IFS= read -r review_id; do
		[[ -z "$review_id" ]] && continue
		gh api -X PUT \
			"repos/${repo_slug}/pulls/${pr_number}/reviews/${review_id}/dismissals" \
			-f message="Auto-dismissed: coderabbit-nits-ok label applied by maintainer (PR #${pr_number})" \
			>/dev/null 2>&1 || true
		echo "[pulse-wrapper] Merge pass: PR #${pr_number} in ${repo_slug} — dismissed CodeRabbit review ${review_id} (t2179)" >>"$LOGFILE"
	done <<<"$ids"

	return 0
}

#######################################
# Verify no branch-protection-required check on a PR is in a failed state.
# Skips PRs with failing CI even when the merge would use --admin
# (which bypasses branch protection).
#
# t2092: Original implementation used `gh pr view --json statusCheckRollup`
# and counted ANY FAILURE/TIMED_OUT conclusion. That over-counted:
#   - Post-merge workflows (e.g. "Sync Issue Hygiene on PR Merge" which
#     runs on push to main and is expected to fail under the t2029
#     github-actions[bot] + protected main limitation)
#   - Advisory / non-required checks outside branch protection
#   - Stale entries from earlier head commits
# Result: PRs were skipped even with all required checks green.
#
# t2104 (GH#19040): switch to `gh pr checks --required` which consults
# branch protection and returns ONLY checks that gate the merge. The
# `bucket` field normalises every state to one of:
#   pass | fail | pending | cancel | skipping
# We block on `fail` and `cancel`; allow `pass`, `pending`, `skipping`
# (pending + skipping preserve the pre-t2104 semantics: --admin handles
# them, and skipping means the check didn't run which isn't a failure).
#
# An empty result (no required checks defined in branch protection) is
# treated as "nothing is failing" → merge allowed. Fail-closed on API
# errors — a bubbling gh failure should never auto-merge.
#
# Arguments: $1=pr_number, $2=repo_slug
# Returns: 0 if all required checks pass/pending/skipping, 1 if any failed
#######################################
_pr_required_checks_pass() {
	local pr_number="$1"
	local repo_slug="$2"
	local failing _gh_exit
	# Separate declaration from assignment to preserve exit code (SC2181).
	failing=$(gh pr checks "$pr_number" --repo "$repo_slug" --required --json bucket \
		--jq '[.[] | select(.bucket == "fail" or .bucket == "cancel")] | length' \
		2>/dev/null)
	_gh_exit=$?
	# Fail-closed: if the API call itself fails, skip the merge rather than
	# silently allowing it (t2092 — --admin bypasses branch protection).
	if [[ $_gh_exit -ne 0 ]]; then
		echo "[pulse-wrapper] Merge pass: skipping PR #${pr_number} in ${repo_slug} — required checks fetch failed (exit ${_gh_exit}) (t2104)" >>"$LOGFILE"
		return 1
	fi
	# Empty string = no required checks; normalise to 0.
	[[ -z "$failing" ]] && failing=0
	if [[ "$failing" -gt 0 ]]; then
		echo "[pulse-wrapper] Merge pass: skipping PR #${pr_number} in ${repo_slug} — ${failing} required status check(s) failing (t2104)" >>"$LOGFILE"
		return 1
	fi
	return 0
}

#######################################
# Route a PR to the appropriate fix worker based on origin label and kind.
#
# Consolidates the shared routing pattern used by the review, conflict, and CI
# gates. Each gate checks exclusion labels, then dispatches worker-origin PRs
# directly and hands over stale interactive PRs before dispatch.
#
# Args:
#   $1 = pr_number
#   $2 = repo_slug
#   $3 = linked_issue (empty string → no routing possible)
#   $4 = kind          (review | conflict | ci)
#   $5 = pr_labels     (optional — comma-separated; fetched if empty)
#   $6 = pr_title      (optional — passed to conflict dispatch)
#
# Returns: 0 if dispatched, 1 if not routable (no match or excluded)
#
# Design: case-statement dispatch over kind — no dynamic function calls.
# Per-kind return semantics are handled by the CALLER, not here.
# t2203 — extracted from three inline blocks in _check_pr_merge_gates
# and _process_single_ready_pr.
#######################################
_route_pr_to_fix_worker() {
	local pr_number="$1"
	local repo_slug="$2"
	local linked_issue="$3"
	local kind="$4"
	local pr_labels="${5:-}"
	local pr_title="${6:-}"

	# No linked issue → nothing to route to
	[[ -z "$linked_issue" ]] && return 1

	# Fetch labels if not provided by caller
	if [[ -z "$pr_labels" ]]; then
		pr_labels=$(gh pr view "$pr_number" --repo "$repo_slug" \
			--json labels --jq '[.labels[].name] | join(",")' 2>/dev/null) || pr_labels=""
	fi

	# Kind-specific "already routed" exclusion label
	local routed_label
	case "$kind" in
		review)   routed_label="review-routed-to-issue" ;;
		conflict) routed_label="conflict-feedback-routed" ;;
		ci)       routed_label="ci-feedback-routed" ;;
		*)
			echo "[pulse-wrapper] _route_pr_to_fix_worker: unknown kind '${kind}'" >>"$LOGFILE"
			return 1
			;;
	esac

	# Check exclusion labels — already routed or no-takeover
	if [[ ",${pr_labels}," == *",${routed_label},"* ]] \
		|| [[ ",${pr_labels}," == *",no-takeover,"* ]]; then
		return 1
	fi

	# Review gate has an additional exclusion for external contributors
	if [[ "$kind" == "review" ]] && [[ ",${pr_labels}," == *",external-contributor,"* ]]; then
		return 1
	fi

	# Worker-origin PRs: dispatch directly
	if [[ ",${pr_labels}," == *",origin:worker,"* ]] \
		|| [[ ",${pr_labels}," == *",origin:worker-takeover,"* ]]; then
		case "$kind" in
			review)   _dispatch_pr_fix_worker "$pr_number" "$repo_slug" "$linked_issue" || true ;;
			conflict) _dispatch_conflict_fix_worker "$pr_number" "$repo_slug" "$linked_issue" "$pr_title" || true ;;
			ci)       _dispatch_ci_fix_worker "$pr_number" "$repo_slug" "$linked_issue" || true ;;
		esac
		return 0
	fi

	# Stale interactive PRs: handover first, then dispatch
	if [[ ",${pr_labels}," == *",origin:interactive,"* ]] \
		&& _interactive_pr_is_stale "$pr_number" "$repo_slug"; then
		_interactive_pr_trigger_handover "$pr_number" "$repo_slug" || true
		case "$kind" in
			review)   _dispatch_pr_fix_worker "$pr_number" "$repo_slug" "$linked_issue" || true ;;
			conflict) _dispatch_conflict_fix_worker "$pr_number" "$repo_slug" "$linked_issue" "$pr_title" || true ;;
			ci)       _dispatch_ci_fix_worker "$pr_number" "$repo_slug" "$linked_issue" || true ;;
		esac
		return 0
	fi

	# Not routable (no matching origin label or not stale)
	return 1
}

#######################################
# Run all merge-eligibility gate checks for a single PR.
# Returns 0 if all gates pass (PR may proceed to merge).
# Returns 1 if any gate fails (PR should be skipped).
# Args: $1=pr_number, $2=repo_slug, $3=pr_author, $4=pr_review, $5=linked_issue
#######################################
_check_pr_merge_gates() {
	local pr_number="$1"
	local repo_slug="$2"
	local pr_author="$3"
	local pr_review="$4"
	local linked_issue="$5"

	# Skip CHANGES_REQUESTED — needs a fix worker, not a merge.
	#
	# t2093: For worker-authored PRs with a linked issue, the "skip and hope"
	# path leaks stuck PRs indefinitely — no human owns worker PRs, the
	# dispatch-dedup guard blocks re-dispatch while the PR is open, and the
	# review-followup pipeline only fires on *merged* PRs. Route the review
	# feedback to the linked issue body and close the PR so the next pulse
	# cycle picks the issue up with fresh context. Interactive PRs are
	# always left alone (their humans own the feedback loop); external
	# contributors go through their own crypto-approval flow.
	#
	# t2179: coderabbit-nits-ok override — if the maintainer applied the
	# label and EVERY CHANGES_REQUESTED reviewer is coderabbitai[bot],
	# auto-dismiss those reviews and fall through to the next gate. If any
	# human reviewer is also blocking, the label is ignored.
	if [[ "$pr_review" == "CHANGES_REQUESTED" ]]; then
		# Fetch labels once — reused by both the nits-ok check and the
		# worker-routing block below.
		local _cr_pr_labels
		_cr_pr_labels=$(gh pr view "$pr_number" --repo "$repo_slug" \
			--json labels --jq '[.labels[].name] | join(",")' 2>/dev/null) || _cr_pr_labels=""

		# t2179: coderabbit-nits-ok path.
		if [[ ",${_cr_pr_labels}," == *",coderabbit-nits-ok,"* ]]; then
			if _pulse_merge_dismiss_coderabbit_nits "$pr_number" "$repo_slug"; then
				echo "[pulse-wrapper] Merge pass: PR #${pr_number} in ${repo_slug} — auto-dismissed CodeRabbit-only CHANGES_REQUESTED reviews (coderabbit-nits-ok label) (t2179)" >>"$LOGFILE"
				# Fall through to the next gate — do NOT return 1.
			else
				echo "[pulse-wrapper] Merge pass: skipping PR #${pr_number} in ${repo_slug} — coderabbit-nits-ok label present but human reviewer also blocking (t2179)" >>"$LOGFILE"
				return 1
			fi
		else
			# No coderabbit-nits-ok label — route worker-authored PRs for fix
			# dispatch and skip the merge (t2203: consolidated in helper).
			_route_pr_to_fix_worker "$pr_number" "$repo_slug" "$linked_issue" "review" "$_cr_pr_labels" || true
			echo "[pulse-wrapper] Merge pass: skipping PR #${pr_number} in ${repo_slug} — reviewDecision=CHANGES_REQUESTED" >>"$LOGFILE"
			return 1
		fi
	fi

	# Skip external contributor PRs (non-collaborator)
	if ! _is_collaborator_author "$pr_author" "$repo_slug"; then
		echo "[pulse-wrapper] Merge pass: skipping PR #${pr_number} in ${repo_slug} — author ${pr_author} is not a collaborator" >>"$LOGFILE"
		return 1
	fi

	# Skip PRs modifying workflow files when we lack the scope
	if check_pr_modifies_workflows "$pr_number" "$repo_slug" 2>/dev/null; then
		if ! check_gh_workflow_scope 2>/dev/null; then
			echo "[pulse-wrapper] Merge pass: skipping PR #${pr_number} in ${repo_slug} — modifies workflow files but token lacks workflow scope" >>"$LOGFILE"
			return 1
		fi
	fi

	# Maintainer-gate: skip if linked issue has needs-maintainer-review
	# UNLESS the issue also has the approval marker comment
	# (<!-- aidevops-signed-approval -->), which means the auto-approve
	# already ran and the NMR label is transient — the CI workflow
	# re-adds it within seconds of removal, creating a race with the
	# merge pass. The approval marker is the source of truth; NMR label
	# is the transient symptom of the CI workflow fighting the pulse.
	if [[ -n "$linked_issue" ]]; then
		local issue_labels
		issue_labels=$(gh api "repos/${repo_slug}/issues/${linked_issue}" \
			--jq '[.labels[].name] | join(",")' 2>/dev/null) || issue_labels=""
		if [[ "$issue_labels" == *"needs-maintainer-review"* ]]; then
			# Check if approval marker exists — if so, NMR is transient
			local _has_approval_marker
			_has_approval_marker=$(gh api "repos/${repo_slug}/issues/${linked_issue}/comments" \
				--jq '[.[].body | select(contains("aidevops-signed-approval"))] | length' \
				2>/dev/null) || _has_approval_marker=0
			if [[ "$_has_approval_marker" -gt 0 ]]; then
				echo "[pulse-wrapper] Merge pass: PR #${pr_number} in ${repo_slug} — linked issue #${linked_issue} has NMR but also approval marker — proceeding (NMR is transient)" >>"$LOGFILE"
			else
				echo "[pulse-wrapper] Merge pass: skipping PR #${pr_number} in ${repo_slug} — linked issue #${linked_issue} has needs-maintainer-review (no approval marker)" >>"$LOGFILE"
				return 1
			fi
		fi
	fi

	# ── External contributor gate (t1958) ──
	# Requires linked issue + crypto approval (defence-in-depth after _is_collaborator_author).
	local pr_labels_for_ext
	pr_labels_for_ext=$(gh pr view "$pr_number" --repo "$repo_slug" --json labels \
		--jq '[.labels[].name] | join(",")' 2>/dev/null) || pr_labels_for_ext=""
	if [[ "$pr_labels_for_ext" == *"external-contributor"* ]]; then
		if ! _external_pr_has_linked_issue "$pr_number" "$repo_slug"; then
			echo "[pulse-wrapper] Merge pass: skipping PR #${pr_number} in ${repo_slug} — external-contributor PR has no linked issue (t1958)" >>"$LOGFILE"
			return 1
		fi
		if ! _external_pr_linked_issue_crypto_approved "$pr_number" "$repo_slug"; then
			local ext_linked_for_log
			ext_linked_for_log=$(_extract_linked_issue "$pr_number" "$repo_slug" 2>/dev/null) || ext_linked_for_log="unknown"
			echo "[pulse-wrapper] Merge pass: skipping PR #${pr_number} in ${repo_slug} — external-contributor PR linked issue #${ext_linked_for_log} lacks crypto approval (t1958)" >>"$LOGFILE"
			return 1
		fi
	fi

	# ── Review bot gate (GH#17490) ──
	# --admin bypasses branch protection; enforce in code (see review-bot-gate-helper.sh).
	local rbg_helper="${AGENTS_DIR:-$HOME/.aidevops/agents}/scripts/review-bot-gate-helper.sh"
	if [[ -f "$rbg_helper" ]]; then
		local rbg_result="" rbg_status=""
		rbg_result=$(bash "$rbg_helper" check "$pr_number" "$repo_slug" 2>/dev/null) || rbg_result=""
		rbg_status=$(printf '%s' "$rbg_result" | grep -oE '^(PASS|SKIP|WAITING|PASS_RATE_LIMITED)' | head -1)
		case "$rbg_status" in
		PASS | SKIP | PASS_RATE_LIMITED)
			echo "[pulse-wrapper] Review bot gate: ${rbg_status} for PR #${pr_number} in ${repo_slug}" >>"$LOGFILE"
			;;
		*)
			echo "[pulse-wrapper] Review bot gate: ${rbg_status:-UNKNOWN} for PR #${pr_number} in ${repo_slug} — skipping merge" >>"$LOGFILE"
			return 1
			;;
		esac
	fi

	return 0
}

#######################################
# Perform all post-merge actions for a successfully merged PR:
# build and post closing comment, close linked issue, unlock.
# Best-effort — failures are logged but do not propagate.
# Args: $1=pr_number, $2=repo_slug, $3=linked_issue, $4=merge_summary
#######################################
_handle_post_merge_actions() {
	local pr_number="$1"
	local repo_slug="$2"
	local linked_issue="$3"
	local merge_summary="$4"

	# Build closing comment — use worker summary if available, fall back to generic
	local closing_comment
	if [[ -n "$merge_summary" ]]; then
		closing_comment="${merge_summary}

---
Merged via PR #${pr_number} to main.
_Merged by deterministic merge pass (pulse-wrapper.sh)._"
	else
		closing_comment="Completed via PR #${pr_number}, merged to main.

_Merged by deterministic merge pass (pulse-wrapper.sh). Neither MERGE_SUMMARY comment nor PR body text was available._"
	fi

	# Append signature footer (GH#15486) — no-session, routine type.
	local _merge_sig_footer="" _merge_elapsed="" _merge_issue_ref=""
	_merge_elapsed=$(($(date +%s) - PULSE_START_EPOCH))
	[[ -n "$linked_issue" ]] && _merge_issue_ref="${repo_slug}#${linked_issue}"
	local _sig_helper="${AGENTS_DIR:-$HOME/.aidevops/agents}/scripts/gh-signature-helper.sh"
	_merge_sig_footer=$("$_sig_helper" footer \
		--body "$closing_comment" --no-session --tokens 0 \
		--time "$_merge_elapsed" --session-type routine \
		${_merge_issue_ref:+--issue "$_merge_issue_ref"} --solved 2>/dev/null || true)
	closing_comment="${closing_comment}${_merge_sig_footer}"

	# Post closing comment on PR; unlock the merged PR (t1934)
	gh_pr_comment "$pr_number" --repo "$repo_slug" \
		--body "$closing_comment" 2>/dev/null || true
	unlock_issue_after_worker "$pr_number" "$repo_slug"

	# Close linked issue with the same closing comment
	if [[ -n "$linked_issue" ]]; then
		# t2099 / GH#19032: parent-task close guard. Parent roadmap issues must
		# stay open until ALL phase children merge (t2046). The PR-body keyword
		# guard (parent-task-keyword-guard.sh) prevents workers from writing
		# Closes/Resolves/Fixes against a parent, and they instead use
		# "For #NNN" / "Ref #NNN". BUT `_extract_linked_issue` also falls back
		# to matching `GH#NNN:` in the PR title — which is the canonical PR
		# title format for parent-task phase PRs. Without this check, every
		# phase PR would silently close its parent on merge.
		#
		# Behaviour:
		#   - Still post the closing comment (it doubles as a phase-merged
		#     status update on the parent).
		#   - SKIP the `gh issue close` call.
		#   - SKIP fast_fail_reset and unlock (both tied to closing).
		local _parent_task_guard=0
		local _linked_labels
		_linked_labels=$(gh api "repos/${repo_slug}/issues/${linked_issue}" \
			--jq '[.labels[].name] | join(",")' 2>/dev/null) || _linked_labels=""
		if [[ ",${_linked_labels}," == *",parent-task,"* ]]; then
			_parent_task_guard=1
			echo "[pulse-wrapper] Deterministic merge: skipping close of parent-task issue #${linked_issue} (PR #${pr_number} is a phase child; parent stays open until all phases merge) — t2099/GH#19032" >>"$LOGFILE"
		fi

		# Dedup guard: skip if closing comment for this PR already exists (GH#18098).
		local _dedup_count
		_dedup_count=$(gh api "repos/${repo_slug}/issues/${linked_issue}/comments" \
			2>/dev/null | jq --arg prnum "PR #${pr_number}" \
			'[.[] | select(.body | contains($prnum))] | length' 2>/dev/null) || _dedup_count=0
		[[ "$_dedup_count" =~ ^[0-9]+$ ]] || _dedup_count=0
		if [[ "$_dedup_count" -gt 0 ]]; then
			echo "[pulse-wrapper] Deterministic merge: skipped duplicate closing comment on #${linked_issue} — PR #${pr_number} already referenced in existing comment (GH#18098)" >>"$LOGFILE"
		else
			gh_issue_comment "$linked_issue" --repo "$repo_slug" \
				--body "$closing_comment" 2>/dev/null || true
		fi

		if [[ "$_parent_task_guard" -eq 0 ]]; then
			gh issue close "$linked_issue" --repo "$repo_slug" 2>/dev/null || true
			# Reset fast-fail counter now that the issue is resolved (GH#2076)
			fast_fail_reset "$linked_issue" "$repo_slug" || true
			# t1934: Unlock the issue (locked at dispatch time)
			unlock_issue_after_worker "$linked_issue" "$repo_slug"
		fi
	fi
	return 0
}

#######################################
# Process a single PR end-to-end: gate checks, merge attempt,
# conflict detection, and closing comment posting.
#
# Extracted from _merge_ready_prs_for_repo (t2002 / GH#18450, Phase 12).
# Decomposed into focused helpers (GH#18682): _resolve_pr_mergeable_status,
# _check_pr_merge_gates, _handle_post_merge_actions.
# Enables per-PR debugging and unit testing in isolation.
#
# Args:
#   $1 - repo slug
#   $2 - PR JSON object (single element from gh pr list --json output)
# Returns:
#   0 = merged successfully
#   1 = skipped (gate failure or non-mergeable)
#   2 = closed conflicting
#   3 = merge failed
#######################################
_process_single_ready_pr() {
	local repo_slug="$1"
	local pr_obj="$2"

	local pr_number pr_mergeable pr_review pr_author pr_title
	# Consolidate into a single jq pass to reduce process-spawn overhead.
	# CRITICAL: use non-whitespace delimiter (ASCII 0x1E record separator)
	# instead of \t. Bash read collapses consecutive IFS whitespace chars
	# (tab, space, newline) — if ANY field is empty the subsequent fields
	# shift left. reviewDecision is routinely "" (empty string, which jq //
	# does NOT catch — it only triggers on null/false). The field shift
	# caused pr_author to receive the PR title, breaking the collaborator
	# check and blocking ALL merges across every repo (GH#awardsapp).
	local _RS=$'\x1e'
	IFS="$_RS" read -r pr_number pr_mergeable pr_review pr_author pr_title < <(
		printf '%s' "$pr_obj" | jq -r \
			'"\(.number // "")\u001e\(.mergeable // "")\u001e\(if (.reviewDecision | length) == 0 then "NONE" else .reviewDecision end)\u001e\(.author.login // "unknown")\u001e\(.title // "")"'
	)

	[[ "$pr_number" =~ ^[0-9]+$ ]] || return 1

	# CONFLICTING handling (t2116): before closing, attempt to salvage the
	# PR via `gh pr update-branch` which fast-forwards the base branch into
	# the PR's branch when the conflict is purely due to base advancement
	# (common case: ratchet PRs on a file that other PRs also touched, docs
	# simplifications on adjacent sections). If update-branch succeeds, the
	# PR may now be MERGEABLE and we re-fetch its state so the normal merge
	# path can take over in the same cycle.
	#
	# This reorders the original flow: we now also check the maintainer gate
	# BEFORE closing, so PRs waiting on `needs-maintainer-review` are never
	# discarded as CONFLICTING during their wait (previous behaviour punished
	# maintainer review latency by throwing away worker work — see t2116
	# post-mortem for PR #18988, #19083).
	if [[ "$pr_mergeable" == "CONFLICTING" && "$PULSE_MERGE_CLOSE_CONFLICTING" == "true" ]]; then
		# Skip CONFLICTING-close entirely for PRs whose linked issue has
		# needs-maintainer-review — they are parked legitimately waiting for
		# a human and MUST NOT be auto-closed (t2116). Post the one-time
		# rebase nudge so the maintainer has a visible signal.
		local _t2116_linked_issue _t2116_issue_labels
		_t2116_linked_issue=$(_extract_linked_issue "$pr_number" "$repo_slug")
		if [[ -n "$_t2116_linked_issue" ]]; then
			_t2116_issue_labels=$(gh api "repos/${repo_slug}/issues/${_t2116_linked_issue}" \
				--jq '[.labels[].name] | join(",")' 2>/dev/null) || _t2116_issue_labels=""
			if [[ "$_t2116_issue_labels" == *"needs-maintainer-review"* ]]; then
				echo "[pulse-wrapper] Merge pass: skipping CONFLICTING-close of PR #${pr_number} in ${repo_slug} — linked issue #${_t2116_linked_issue} has needs-maintainer-review (t2116)" >>"$LOGFILE"
				_post_rebase_nudge_on_worker_conflicting "$pr_number" "$repo_slug" "" "" 2>/dev/null || true
				return 1
			fi
		fi

		# Attempt auto-rebase via gh pr update-branch. This is idempotent
		# and cheap: on success the branch is fast-forwarded and the next
		# mergeable re-fetch returns MERGEABLE; on failure (true semantic
		# conflict) we fall through to the close path.
		if _attempt_pr_update_branch "$pr_number" "$repo_slug"; then
			# Re-fetch mergeable state after update-branch; GitHub needs a
			# moment to recompute it. _resolve_pr_mergeable_status already
			# has a UNKNOWN-retry loop so we reuse it.
			local _refetched_mergeable
			_refetched_mergeable=$(gh pr view "$pr_number" --repo "$repo_slug" \
				--json mergeable --jq '.mergeable // "UNKNOWN"' 2>/dev/null) || _refetched_mergeable="UNKNOWN"
			pr_mergeable="$_refetched_mergeable"
			echo "[pulse-wrapper] Merge pass: PR #${pr_number} in ${repo_slug} — update-branch succeeded, refetched mergeable=${pr_mergeable} (t2116)" >>"$LOGFILE"
			# If still CONFLICTING after a successful update-branch, the
			# conflict is semantic and unsalvageable. Fall through to close.
		fi

		if [[ "$pr_mergeable" == "CONFLICTING" ]]; then
			# Conflict resolution feedback: route worker PRs to fix worker
			# (t2203: consolidated in helper). If routed, return 2 to skip
			# the close path; otherwise fall through to _close_conflicting_pr.
			local _conf_linked_issue
			_conf_linked_issue=$(_extract_linked_issue "$pr_number" "$repo_slug")
			if _route_pr_to_fix_worker "$pr_number" "$repo_slug" "$_conf_linked_issue" "conflict" "" "$pr_title"; then
				return 2
			fi
			_close_conflicting_pr "$pr_number" "$repo_slug" "$pr_title"
			return 2
		fi
		# Otherwise pr_mergeable is now MERGEABLE/UNKNOWN — continue through
		# the normal merge path below.
	fi

	# Resolve UNKNOWN mergeable state with one retry; skip if not MERGEABLE
	if ! _resolve_pr_mergeable_status "$pr_number" "$repo_slug" "$pr_mergeable"; then
		return 1
	fi

	# CI failure fix-up: when required checks fail on a worker PR with a
	# linked issue, collect failing check details, append to issue body,
	# close the PR, and set the issue to status:available for re-dispatch.
	# The next worker sees the CI failure context and can fix it. t2189:
	# idle interactive PRs are handed over via origin:worker-takeover and
	# then routed through the same pipeline — human session must be gone
	# (no status, no claim stamp, >24h idle) for handover to fire.
	if ! _pr_required_checks_pass "$pr_number" "$repo_slug"; then
		# CI failure: route to fix worker if applicable (t2203: consolidated).
		local _ci_linked_issue
		_ci_linked_issue=$(_extract_linked_issue "$pr_number" "$repo_slug")
		_route_pr_to_fix_worker "$pr_number" "$repo_slug" "$_ci_linked_issue" "ci" || true
		return 1
	fi

	# Fetch linked issue once — used in gate checks and post-merge close
	local linked_issue
	linked_issue=$(_extract_linked_issue "$pr_number" "$repo_slug")

	# Run all skip-gate checks (review decision, collaborator, workflow scope,
	# maintainer gate, external-contributor gate, review bot gate)
	if ! _check_pr_merge_gates "$pr_number" "$repo_slug" "$pr_author" "$pr_review" "$linked_issue"; then
		return 1
	fi

	# Approve (satisfies REVIEW_REQUIRED for collaborator PRs)
	approve_collaborator_pr "$pr_number" "$repo_slug" "$pr_author" 2>/dev/null || true

	# Extract merge summary: MERGE_SUMMARY comment → PR body → generic fallback
	local merge_summary
	merge_summary=$(_extract_merge_summary "$pr_number" "$repo_slug")

	# Merge
	local merge_output _merge_exit
	merge_output=$(gh pr merge "$pr_number" --repo "$repo_slug" --squash --admin 2>&1)
	_merge_exit=$?

	# Rate-limit: 1 second between merges to avoid GitHub API abuse
	sleep 1

	if [[ $_merge_exit -eq 0 ]]; then
		echo "[pulse-wrapper] Deterministic merge: merged PR #${pr_number} in ${repo_slug}" >>"$LOGFILE"
		_handle_post_merge_actions "$pr_number" "$repo_slug" "$linked_issue" "$merge_summary"
		return 0
	else
		echo "[pulse-wrapper] Deterministic merge: FAILED PR #${pr_number} in ${repo_slug}: ${merge_output}" >>"$LOGFILE"
		return 3
	fi
}

#######################################
# Check if a PR author is a collaborator (admin/maintain/write).
# Args: $1=author login, $2=repo slug
# Returns: 0=collaborator, 1=not collaborator or error
#######################################
_is_collaborator_author() {
	local author="$1"
	local repo_slug="$2"
	local perm_response
	perm_response=$(gh api -i "repos/${repo_slug}/collaborators/${author}/permission" 2>/dev/null | head -1)
	if [[ "$perm_response" == *"200"* ]]; then
		local perm
		perm=$(gh api "repos/${repo_slug}/collaborators/${author}/permission" --jq '.permission' 2>/dev/null)
		case "$perm" in
		admin | maintain | write) return 0 ;;
		esac
	fi
	return 1
}

#######################################
# Extract linked issue number from PR title or body.
# Looks for: GitHub-native close keywords in PR body, "GH#NNN:" prefix in title.
#
# Close keyword matching (GH#18098): only GitHub-native keywords trigger auto-close —
# bare GH#NNN references in "Related" sections do NOT.  GitHub's full keyword list:
# close, closes, closed, fix, fixes, fixed, resolve, resolves, resolved (case-insensitive).
# GH#NNN matching is restricted to the PR title to avoid treating informational body
# references as closing keywords.
#
# Args: $1=PR number, $2=repo slug
# Returns: issue number on stdout, or empty if none found
#######################################
_extract_linked_issue() {
	local pr_number="$1"
	local repo_slug="$2"
	local pr_title pr_body
	pr_title=$(gh pr view "$pr_number" --repo "$repo_slug" --json title --jq '.title // empty' 2>/dev/null) || pr_title=""
	pr_body=$(gh pr view "$pr_number" --repo "$repo_slug" --json body --jq '.body // empty' 2>/dev/null) || pr_body=""

	# Match GitHub-native close keywords in the PR body only (case-insensitive).
	# Matches: close/closes/closed, fix/fixes/fixed, resolve/resolves/resolved.
	# Does NOT match bare GH#NNN, "Related #NNN", "For #NNN", "Ref #NNN", or other
	# non-closing references. (GH#18098 + t2108)
	#
	# The body keyword is AUTHORITATIVE. The title fallback below only fires when
	# the body has a closing keyword AND the title also names a number — it picks
	# WHICH issue from the body matches when there are multiple. It is NEVER an
	# override that creates a match where the body intentionally has none. (t2108)
	local body_issue title_issue
	body_issue=$(printf '%s' "$pr_body" | grep -ioE '(close[ds]?|fix(es|ed)?|resolve[ds]?)\s+#[0-9]+' | head -1 | grep -oE '[0-9]+')
	title_issue=$(printf '%s' "$pr_title" | grep -oE 'GH#[0-9]+' | head -1 | grep -oE '[0-9]+')

	# No closing keyword in the body → return empty. The PR is intentionally
	# not closing any issue (planning-only PR, multi-PR roadmap, "For #NNN"
	# reference, etc.). _handle_post_merge_actions will skip the close path
	# when this returns empty. (t2108)
	if [[ -z "$body_issue" ]]; then
		return 0
	fi

	# Body has a closing keyword. If the title also names a number, prefer the
	# title-named issue when it differs from body_issue (matches the historical
	# behaviour where the GH#NNN: title prefix is the primary identifier and
	# the body may reference additional issues). When they match or the title
	# has no number, return body_issue. (t2108)
	if [[ -n "$title_issue" ]]; then
		printf '%s' "$title_issue"
		return 0
	fi
	printf '%s' "$body_issue"
	return 0
}

#######################################
# Extract the worker's merge summary from PR comments.
#
# Workers post a structured comment tagged with <!-- MERGE_SUMMARY -->
# on the PR at creation time (full-loop.md step 4.2.1). This function
# finds the most recent such comment and returns its body (without the
# HTML tag) for use in closing comments.
#
# Args: $1=PR number, $2=repo slug
# Output: merge summary text on stdout (empty if none found)
#######################################
_extract_merge_summary() {
	local pr_number="$1"
	local repo_slug="$2"

	# Strategy 1: Look for explicit MERGE_SUMMARY tagged comment (richest content)
	local summary
	summary=$(gh api "repos/${repo_slug}/issues/${pr_number}/comments" \
		--jq '[.[] | select(.body | test("<!-- MERGE_SUMMARY -->"))] | last | .body // empty' \
		2>/dev/null) || summary=""

	if [[ -n "$summary" ]]; then
		# Strip the HTML marker tag
		summary=$(printf '%s' "$summary" | sed 's/<!-- MERGE_SUMMARY -->//')
		# Strip the worker's "written at PR creation time" note if present
		summary=$(printf '%s' "$summary" | sed '/written by the worker at PR creation time/d')
		printf '%s' "$summary"
		return 0
	fi

	# Strategy 2: Extract from PR body (always present, created atomically with PR).
	# Workers skip the MERGE_SUMMARY comment ~65% of the time, but the PR body
	# always contains a useful description of what was done (GH#17503).
	local pr_body
	pr_body=$(gh pr view "$pr_number" --repo "$repo_slug" \
		--json body --jq '.body // empty' 2>/dev/null) || pr_body=""

	if [[ -z "$pr_body" ]]; then
		return 0
	fi

	# Strip auto-generated bot content (CodeRabbit, SonarCloud, Codacy, etc.)
	# These start with <!-- This is an auto-generated comment or similar markers
	pr_body=$(printf '%s\n' "$pr_body" | sed '/<!-- This is an auto-generated comment/,$d')

	# Strip Closes/Fixes/Resolves #NNN (the closing comment adds its own PR reference)
	pr_body=$(printf '%s\n' "$pr_body" | sed -E 's/(Closes|Fixes|Resolves) #[0-9]+[[:space:]]*//')

	# Trim leading/trailing blank lines (BSD sed compatible)
	pr_body=$(printf '%s\n' "$pr_body" | sed '/./,$!d' | sed -E '/^[[:space:]]*$/{ N; }' | sed -E '/^[[:space:]]*$/d')

	# Only use if there's meaningful content left (more than just whitespace)
	if [[ -n "$pr_body" ]] && [[ "$(printf '%s' "$pr_body" | tr -d '[:space:]')" != "" ]]; then
		printf '%s' "$pr_body"
	fi

	return 0
}
