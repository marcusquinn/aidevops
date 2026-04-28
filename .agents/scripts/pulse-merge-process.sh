#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# pulse-merge-process.sh — Merge Processing Helpers
# =============================================================================
# Extracted from pulse-merge.sh (GH#21301) to bring the parent file below
# the 1500-line file-size-debt threshold.
#
# Covers the merge iteration and helper functions that support the merge
# pipeline:
#   - merge_ready_prs_all_repos           — top-level merge pass entry point
#   - _merge_ready_prs_for_repo           — per-repo PR iteration
#   - _attempt_pr_update_branch           — fast-forward via update-branch
#   - _resolve_pr_mergeable_status        — UNKNOWN→MERGEABLE retry
#   - _pulse_merge_dismiss_coderabbit_nits — auto-dismiss CR-only reviews
#   - _pr_required_checks_pass            — required CI check verification
#   - _attempt_pr_ci_rebase_retry         — CI-drift rebase (t2805)
#   - _route_pr_to_fix_worker             — unified fix-worker dispatch (t2203)
#   - _retarget_stacked_children          — stacked PR retargeting (t2412)
#   - _attempt_worker_briefed_auto_merge  — worker-briefed trust chain (t2449)
#   - _check_required_checks_passing      — branch-protection context check (t2922)
#
# Usage: source "${SCRIPT_DIR}/pulse-merge-process.sh"
#        (sourced by pulse-merge.sh after pulse-merge-gates.sh)
#
# Dependencies:
#   - shared-constants.sh (gh_pr_list, gh_pr_comment, gh_issue_comment, etc.)
#   - worker-lifecycle-common.sh (unlock_issue_after_worker)
#   - LOGFILE, STOP_FLAG, PULSE_MERGE_BATCH_LIMIT (set by pulse-merge.sh defaults)
#   - _OW_LABEL_PAT (defined in pulse-merge.sh before sourcing this file)
#   - _pm_issue_api (defined in pulse-merge.sh before sourcing this file)
#   - _process_single_ready_pr (defined in pulse-merge.sh, resolved at call time)
#   - _dispatch_pr_fix_worker, _dispatch_conflict_fix_worker, _dispatch_ci_fix_worker
#     (defined in pulse-merge-feedback.sh, resolved at call time)
#   - _interactive_pr_is_stale, _interactive_pr_trigger_handover
#     (defined in pulse-merge-conflict.sh, resolved at call time)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_PULSE_MERGE_PROCESS_LOADED:-}" ]] && return 0
_PULSE_MERGE_PROCESS_LOADED=1

# Defensive defaults for standalone sourcing (test harnesses, pulse-merge-routine.sh)
: "${LOGFILE:=${HOME}/.aidevops/logs/pulse.log}"
: "${STOP_FLAG:=${HOME}/.aidevops/logs/pulse-session.stop}"
: "${PULSE_MERGE_BATCH_LIMIT:=50}"

# --- Functions ---

merge_ready_prs_all_repos() {
	# Initialise required env vars with ${VAR:-default} guards so this
	# function can be called standalone from pulse-merge-routine.sh (t2862)
	# without relying on pulse-wrapper.sh having set them in the bootstrap.
	# When called from pulse-wrapper.sh the pre-existing values are kept.
	local _mr_stop_flag="${STOP_FLAG:-${HOME}/.aidevops/logs/pulse-session.stop}"
	local _mr_repos_json="${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"
	local _mr_logfile="${LOGFILE:-${HOME}/.aidevops/logs/pulse.log}"
	PULSE_MERGE_BATCH_LIMIT="${PULSE_MERGE_BATCH_LIMIT:-50}"

	if [[ -f "$_mr_stop_flag" ]]; then
		echo "[pulse-wrapper] Deterministic merge pass skipped: stop flag present" >>"$_mr_logfile"
		return 0
	fi

	if [[ ! -f "$_mr_repos_json" ]]; then
		echo "[pulse-wrapper] Deterministic merge pass skipped: repos.json not found" >>"$_mr_logfile"
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

		if [[ -f "$_mr_stop_flag" ]]; then
			echo "[pulse-wrapper] Deterministic merge pass: stop flag appeared mid-run" >>"$_mr_logfile"
			break
		fi
	done < <(jq -r '.initialized_repos[] | select(.pulse == true and (.local_only // false) == false and .slug != "") | [.slug, .path] | join("|")' "$_mr_repos_json" 2>/dev/null)

	echo "[pulse-wrapper] Deterministic merge pass complete: merged=${total_merged}, closed_conflicting=${total_closed}, failed=${total_failed}" >>"$_mr_logfile"
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
	pr_json=$(gh_pr_list --repo "$repo_slug" --state open \
		--json number,mergeable,reviewDecision,author,title \
		--limit "$PULSE_MERGE_BATCH_LIMIT" 2>"$pr_merge_err") || pr_json="[]"
	if [[ -z "$pr_json" || "$pr_json" == "null" ]]; then
		local _pr_merge_err_msg
		_pr_merge_err_msg=$(cat "$pr_merge_err" 2>/dev/null || echo "unknown error")
		echo "[pulse-wrapper] _process_merge_batch: gh_pr_list FAILED for ${repo_slug}: ${_pr_merge_err_msg}" >>"$LOGFILE"
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
# t2104 (GH#19040): switch to `gh pr checks --required` which consults
# branch protection and returns ONLY checks that gate the merge.
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
# Attempt to rebase a MERGEABLE PR with failing CI before routing to a
# fix-worker. When a PR is behind its base branch, failing CI is often
# caused by base-drift (e.g. a pre-existing test failure fixed in a
# later commit to the base branch), not by the PR's own code.
#
# Returns 0 if update-branch succeeded (caller should skip fix-worker
# routing and let the next pulse cycle re-check CI on the rebased HEAD).
# Returns 1 if the PR is already up-to-date with its base or if
# update-branch failed (caller should fall through to fix-worker routing).
#
# Rate-limit: one call per PR per merge cycle — same as t2116.
#
# Args: $1=pr_number, $2=repo_slug
# t2805
#######################################
_attempt_pr_ci_rebase_retry() {
	local pr_number="$1"
	local repo_slug="$2"

	# Fetch baseRefName and headRefOid in a single gh pr view call.
	local _pr_info _base_branch _head_oid
	_pr_info=$(gh pr view "$pr_number" --repo "$repo_slug" \
		--json baseRefName,headRefOid --jq '(.baseRefName // "") + " " + (.headRefOid // "")' 2>/dev/null) || _pr_info=""
	read -r _base_branch _head_oid <<< "$_pr_info"

	if [[ -n "$_base_branch" && -n "$_head_oid" ]]; then
		local _compare_behind
		_compare_behind=$(gh api "repos/${repo_slug}/compare/${_base_branch}...${_head_oid}" \
			--jq '.behind_by' 2>/dev/null) || _compare_behind=""
		if [[ "$_compare_behind" == "0" ]]; then
			echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: already up-to-date with ${_base_branch}, skipping CI-drift rebase (t2805)" >>"$LOGFILE"
			return 1
		fi
	fi

	echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: attempting CI-drift rebase via update-branch (t2805)" >>"$LOGFILE"

	local _ub_output _ub_exit
	_ub_output=$(gh pr update-branch "$pr_number" --repo "$repo_slug" 2>&1)
	_ub_exit=$?

	if [[ $_ub_exit -eq 0 ]]; then
		echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: CI-drift rebase succeeded via update-branch, deferring to next cycle (t2805)" >>"$LOGFILE"
		return 0
	fi

	echo "[pulse-merge] PR #${pr_number} in ${repo_slug}: CI-drift rebase failed (update-branch exit ${_ub_exit}), falling through to fix-worker routing (t2805): ${_ub_output}" >>"$LOGFILE"
	return 1
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
	if [[ ",${pr_labels}," == *"${_OW_LABEL_PAT}"* ]] \
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
# Retarget any open PRs that are stacked on the head branch of a PR
# that is about to be merged (and its branch deleted). GitHub auto-closes
# stacked children when their base branch disappears; retargeting to main
# before the delete prevents the auto-close.
#
# Limitation: only direct children are retargeted. Grandchildren are
# naturally handled when their own parent PR merges and retargets them.
#
# Args:
#   $1 - parent PR number (the PR being merged)
#   $2 - repo slug
# Returns: 0 always (errors are non-fatal)
#######################################
_retarget_stacked_children() {
	local parent_pr_number="$1"
	local repo_slug="$2"
	local parent_head_ref
	parent_head_ref=$(gh pr view "$parent_pr_number" --repo "$repo_slug" --json headRefName -q '.headRefName' 2>/dev/null) || parent_head_ref=""
	if [[ -z "$parent_head_ref" ]]; then
		return 0
	fi

	local children
	children=$(gh_pr_list --repo "$repo_slug" --base "$parent_head_ref" --state open --json number -q '.[].number' 2>/dev/null) || children=""
	if [[ -z "$children" ]]; then
		return 0
	fi

	local default_branch
	default_branch=$(gh repo view "$repo_slug" --json defaultBranchRef -q '.defaultBranchRef.name' 2>/dev/null || true)
	default_branch="${default_branch:-main}"

	local child
	while IFS= read -r child; do
		[[ -z "$child" ]] && continue
		echo "[pulse-merge] retargeting stacked PR #${child} from '${parent_head_ref}' to '${default_branch}' before deleting parent PR #${parent_pr_number} branch (t2412)" >>"$LOGFILE"
		gh pr edit "$child" --repo "$repo_slug" --base "$default_branch" 2>&1 | tee -a "$LOGFILE" || true
	done <<<"$children"
	return 0
}

#######################################
# Check origin:worker worker-briefed auto-merge gates (t2449).
#
# Sibling to _check_interactive_pr_gates — validates that an origin:worker
# PR is eligible for auto-merge based on the maintainer-briefed trust chain.
# Called from _check_pr_merge_gates when the PR carries origin:worker.
#
# The trust-chain equivalence argument: if the underlying issue was filed by
# the repo OWNER/MEMBER, the worker faithfully implemented, CI confirms
# correctness, and no human reviewer objected, the trust chain is equivalent
# to (or stronger than) an origin:interactive auto-merge.
#
# Nine criteria (see GH#20204):
#   1. PR carries origin:worker label (caller pre-checks)
#   2. Linked issue authored by OWNER or MEMBER
#   3. NMR never applied OR cleared via cryptographic approval (not auto-approval)
#   4. All required status checks PASS/SKIPPED (checked by general gates)
#   5. No CHANGES_REQUESTED from human reviewers (checked by general gates)
#   6. PR is not a draft
#   7. No hold-for-review label
#   8. Passes review-bot-gate (checked by general gates)
#   9. No origin:worker-takeover label (caller pre-checks)
#
# Feature flag: AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE (default: 1=on, 0=off)
# When OFF, all origin:worker PRs fall back to manual merge only.
#
# Args: $1=pr_number, $2=repo_slug, $3=labels_str (comma-separated),
#       $4=is_draft, $5=linked_issue
# Returns: 0=all gates pass (eligible for auto-merge), 1=blocked
#######################################
_attempt_worker_briefed_auto_merge() {
	local pr_number="$1"
	local repo_slug="$2"
	local labels_str="$3"
	local is_draft="$4"
	local linked_issue="$5"

	# Feature flag — when OFF, all origin:worker PRs fall back to manual merge
	if [[ "${AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE:-1}" == "0" ]]; then
		echo "[pulse-merge] worker-briefed auto-merge: disabled by AIDEVOPS_WORKER_BRIEFED_AUTO_MERGE=0 for PR #${pr_number} in ${repo_slug} (t2449)" >>"$LOGFILE"
		return 1
	fi

	# Gate: not a draft
	if [[ "$is_draft" == "true" ]]; then
		echo "[pulse-merge] worker-briefed auto-merge: skipping PR #${pr_number} in ${repo_slug} — draft PR not eligible (t2449)" >>"$LOGFILE"
		return 1
	fi

	# Gate: no hold-for-review opt-out label
	if [[ ",${labels_str}," == *",hold-for-review,"* ]]; then
		echo "[pulse-merge] worker-briefed auto-merge: skipping PR #${pr_number} in ${repo_slug} — hold-for-review label (t2449)" >>"$LOGFILE"
		return 1
	fi

	# Gate: must have a linked issue (the "brief" in "maintainer-briefed")
	if [[ -z "$linked_issue" ]]; then
		echo "[pulse-merge] worker-briefed auto-merge: skipping PR #${pr_number} in ${repo_slug} — no linked issue (t2449)" >>"$LOGFILE"
		return 1
	fi

	# Gate: linked issue author is OWNER or MEMBER (maintainer-briefed)
	# Reuse the issue API base path for both the author-association and NMR checks.
	local _issue_api
	_issue_api=$(_pm_issue_api "$repo_slug" "$linked_issue")
	local issue_author_assoc
	issue_author_assoc=$(gh api "${_issue_api}" \
		--jq '.author_association // ""' 2>/dev/null) || issue_author_assoc=""
	if [[ "$issue_author_assoc" != "OWNER" && "$issue_author_assoc" != "MEMBER" ]]; then
		echo "[pulse-merge] worker-briefed auto-merge: skipping PR #${pr_number} in ${repo_slug} — linked issue #${linked_issue} author_association=${issue_author_assoc} (not OWNER/MEMBER) (t2449)" >>"$LOGFILE"
		return 1
	fi

	# Gate: NMR crypto-vs-auto approval check.
	# If NMR was ever applied to the linked issue, it must have been cleared
	# via cryptographic approval (sudo aidevops approve issue N), NOT via
	# auto_approve_maintainer_issues. Auto-approval runs as the pulse's own
	# GitHub token — accepting it here would create a closed loop with zero
	# human touchpoints (scanner → issue → dispatch → worker → PR → merge).
	local _nmr_markers
	_nmr_markers=$(gh api "${_issue_api}/comments" --jq '
		[
			(any(.[].body | strings; contains("aidevops:approval-signature:"))),
			(any(.[].body | strings; contains("auto-approved-maintainer-issue")))
		] | @tsv
	' 2>/dev/null) || _nmr_markers="false	false"

	local _has_crypto _has_auto
	read -r _has_crypto _has_auto <<< "$_nmr_markers"

	if [[ "$_has_auto" == "true" && "$_has_crypto" != "true" ]]; then
		echo "[pulse-merge] worker-briefed auto-merge: skipping PR #${pr_number} in ${repo_slug} — linked issue #${linked_issue} NMR was auto-approved only (no crypto clearance) (t2449)" >>"$LOGFILE"
		return 1
	fi

	# All gates pass — eligible for worker-briefed auto-merge
	echo "[pulse-merge] worker-briefed auto-merge: PR #${pr_number} in ${repo_slug} passed all gates (issue #${linked_issue}, author_assoc=${issue_author_assoc}) (t2449)" >>"$LOGFILE"
	return 0
}

#######################################
# Verify all branch-protection-required check contexts have passed on a PR.
#
# Uses the branch protection API as the authoritative source for required
# contexts — more precise than `gh pr checks --required` which can be
# confused by null-status non-required checks (CodeRabbit, qlty, linked-
# issue-check, url-allowlist, etc.) that report indefinitely and trigger the
# fail-closed path spuriously. (t2922)
#
# Called from _process_single_ready_pr to provide an escape hatch for
# origin:worker PRs when _pr_required_checks_pass fires on phantom pending
# contexts that are absent from branch_protection.required_status_checks.
#
# Passing state for each required context:
#   - StatusContext: state == SUCCESS
#   - CheckRun: conclusion in {SUCCESS, NEUTRAL, SKIPPED}
# Any context absent from the rollup, or in any other state, is non-passing.
# Fail-closed on API errors.
#
# Args: $1=repo_slug, $2=pr_number
# Returns: 0=all required contexts passing, 1=some not passing or API error
#######################################
_check_required_checks_passing() {
	local repo_slug="$1"
	local pr_number="$2"

	# Resolve default branch (required to query branch protection endpoint).
	local default_branch _db_exit
	default_branch=$(gh api "repos/${repo_slug}" \
		--jq '.default_branch' 2>/dev/null)
	_db_exit=$?
	if [[ $_db_exit -ne 0 || -z "$default_branch" ]]; then
		echo "[pulse-merge] _check_required_checks_passing: failed to resolve default branch for ${repo_slug} — failing closed (t2922)" >>"$LOGFILE"
		return 1
	fi

	# Fetch required contexts from branch protection — authoritative list.
	local required_contexts _rc_exit
	required_contexts=$(gh api \
		"repos/${repo_slug}/branches/${default_branch}/protection/required_status_checks" \
		--jq '.contexts // [] | .[]' 2>/dev/null)
	_rc_exit=$?
	if [[ $_rc_exit -ne 0 ]]; then
		echo "[pulse-merge] _check_required_checks_passing: branch protection API failed for ${repo_slug} (exit ${_rc_exit}) — failing closed (t2922)" >>"$LOGFILE"
		return 1
	fi

	# No required contexts → nothing required, treat as passing.
	if [[ -z "$required_contexts" ]]; then
		echo "[pulse-merge] _check_required_checks_passing: no required contexts for ${repo_slug} — allowing (t2922)" >>"$LOGFILE"
		return 0
	fi

	# Fetch PR statusCheckRollup to get actual check states.
	local rollup_json _ru_exit
	rollup_json=$(gh pr view "$pr_number" --repo "$repo_slug" \
		--json statusCheckRollup \
		--jq '.statusCheckRollup // []' 2>/dev/null)
	_ru_exit=$?
	if [[ $_ru_exit -ne 0 ]]; then
		echo "[pulse-merge] _check_required_checks_passing: statusCheckRollup fetch failed for PR #${pr_number} in ${repo_slug} — failing closed (t2922)" >>"$LOGFILE"
		return 1
	fi
	[[ -z "$rollup_json" ]] && rollup_json="[]"

	# Build JSON array from newline-delimited required_contexts string.
	local req_json
	req_json=$(printf '%s' "$required_contexts" \
		| jq -Rsc '[split("\n")[] | select(length > 0)]' 2>/dev/null) || req_json="[]"

	# Count required contexts that are not in a passing state.
	local failing_count _fc_exit
	failing_count=$(jq -n \
		--argjson req "$req_json" \
		--argjson checks "$rollup_json" \
		'$req | map(
			. as $ctx |
			($checks | map(select((.name // .context // "") == $ctx)) | last) as $c |
			if $c == null then "NOT_FOUND"
			elif (($c.state // "" | ascii_upcase) == "SUCCESS") then "PASS"
			elif (($c.conclusion // "" | ascii_upcase)
				| . == "SUCCESS" or . == "NEUTRAL" or . == "SKIPPED") then "PASS"
			else "FAIL"
			end
		) | map(select(. != "PASS")) | length' 2>/dev/null)
	_fc_exit=$?

	if [[ $_fc_exit -ne 0 || -z "$failing_count" ]]; then
		echo "[pulse-merge] _check_required_checks_passing: jq evaluation failed for PR #${pr_number} in ${repo_slug} — failing closed (t2922)" >>"$LOGFILE"
		return 1
	fi

	if [[ "$failing_count" -gt 0 ]]; then
		echo "[pulse-merge] _check_required_checks_passing: ${failing_count} required context(s) not passing for PR #${pr_number} in ${repo_slug} (t2922)" >>"$LOGFILE"
		return 1
	fi

	echo "[pulse-merge] _check_required_checks_passing: all required contexts passing for PR #${pr_number} in ${repo_slug} (t2922)" >>"$LOGFILE"
	return 0
}
