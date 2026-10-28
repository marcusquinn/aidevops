#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-merge-issue-closeout.sh — Linked-issue and partial-parent closeout
#
# Sourced by pulse-merge.sh (GH#21426). Functions resolve dependencies lazily
# through that orchestrator: _pm_issue_api, _extract_linked_issue, GitHub wrappers,
# dispatch-label cleanup, phase filing, and worker lifecycle helpers.
# _pm_close_primary_linked_issue also uses the caller's dynamically scoped
# pr_labels, _parent_task_guard, and _linked_labels; keep that calling contract.
# This library only defines functions and never performs closeout at source time.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard — preserve definitions when sourced more than once.
[[ -n "${_PULSE_MERGE_ISSUE_CLOSEOUT_LOADED:-}" ]] && return 0
_PULSE_MERGE_ISSUE_CLOSEOUT_LOADED=1

#######################################
# Resolve the original issue behind a superseded PR reference.
#
# When PR B resolves PR A, GitHub treats PR A as an issue number. The normal
# linked-issue extractor therefore returns PR A's number, not the issue that PR A
# originally resolved. If PR A is actually a pull request, inspect PR A and return
# its own linked issue so deterministic merge can close the original task too.
#
# Args: $1=merged_pr_number, $2=repo_slug, $3=candidate_issue_number
# Stdout: original issue number, or empty when candidate is not a PR chain
# Returns: 0 always
#######################################
_pm_resolve_superseded_original_issue() {
	local merged_pr_number="$1" repo_slug="$2" candidate_issue="$3"
	local original_issue

	[[ -z "$candidate_issue" ]] && return 0
	if ! gh api "repos/${repo_slug}/pulls/${candidate_issue}" >/dev/null 2>&1; then
		return 0
	fi

	original_issue=$(_extract_linked_issue "$candidate_issue" "$repo_slug" 2>/dev/null) || original_issue=""
	if [[ -z "$original_issue" || "$original_issue" == "$candidate_issue" || "$original_issue" == "$merged_pr_number" ]]; then
		return 0
	fi

	printf '%s' "$original_issue"
	return 0
}

#######################################
# Extract a non-closing parent/umbrella reference from a PR body.
#
# Args: $1=pr_number, $2=repo_slug
# Stdout: issue number from the first `For #NNN` / `Ref #NNN` reference
# Returns: 0 always
#######################################
_pm_extract_partial_parent_reference() {
	local pr_number="$1"
	local repo_slug="$2"
	local pr_body="" parent_issue=""

	pr_body=$(gh_pr_view "$pr_number" --repo "$repo_slug" --json body --jq '.body // empty' 2>/dev/null) || pr_body=""
	parent_issue=$(printf '%s' "$pr_body" | grep -ioE '(^|[[:space:]])(for|ref)[[:space:]]+#[0-9]+' | head -1 | grep -oE '[0-9]+') || parent_issue=""
	printf '%s' "$parent_issue"
	return 0
}

#######################################
# Decide whether an issue is broad enough to require partial closeout hygiene.
#
# Args: $1=issue body, $2=comma-separated label names
# Returns: 0=broad parent/umbrella issue, 1=normal leaf issue
#######################################
_pm_issue_needs_partial_closeout() {
	local issue_body="$1"
	local issue_labels="$2"
	local checklist_count

	if [[ ",${issue_labels}," == *"${_PM_PARENT_TASK_LABEL_NEEDLE}"* ]]; then
		return 0
	fi

	if printf '%s' "$issue_body" | grep -qiE '\b(parent|umbrella|roadmap|lifecycle|incident|acceptance criteria)\b'; then
		return 0
	fi

	checklist_count=$(printf '%s' "$issue_body" | grep -cE '^[[:space:]]*[-*+][[:space:]]*\[[ xX]\]' || true)
	[[ "$checklist_count" =~ ^[0-9]+$ ]] || checklist_count=0
	if [[ "$checklist_count" -ge 2 ]]; then
		return 0
	fi

	return 1
}

#######################################
# Extract unchecked acceptance criteria as a Markdown bullet list.
#
# Args: $1=issue body
# Stdout: bullet list (or a conservative fallback)
# Returns: 0 always
#######################################
_pm_unmet_acceptance_criteria() {
	local issue_body="$1"
	local criteria

	criteria=$(printf '%s' "$issue_body" | sed -nE 's/^[[:space:]]*[-*+][[:space:]]*\[[[:space:]]\][[:space:]]*/- /p' | head -20) || criteria=""
	if [[ -z "$criteria" ]]; then
		criteria="- Review the parent issue acceptance criteria and file worker-ready child issues for remaining scope."
	fi
	printf '%s' "$criteria"
	return 0
}

#######################################
# Post partial parent/umbrella closeout when a For/Ref PR merges.
#
# Non-closing references intentionally do not flow through the normal linked
# issue close path. This helper keeps the parent open but leaves an explicit
# closeout trail naming delivered work and follow-ups so broad parents are not
# left ambiguous after a leaf PR merge (GH#23937).
#
# Args: $1=pr_number, $2=repo_slug, $3=merge_summary, $4=linked_issue (optional)
# Returns: 0 always (best-effort post-merge hygiene)
#######################################
_pm_handle_partial_parent_closeout() {
	local pr_number="$1"
	local repo_slug="$2"
	local merge_summary="$3"
	local linked_issue="${4:-}"
	local parent_issue="" issue_api="" issue_json="" issue_body="" issue_labels="" dedup_count="" followups="" delivered_body=""

	parent_issue=$(_pm_extract_partial_parent_reference "$pr_number" "$repo_slug") || parent_issue=""
	[[ -n "$parent_issue" ]] || return 0
	[[ "$parent_issue" != "$linked_issue" ]] || return 0

	issue_api=$(_pm_issue_api "$repo_slug" "$parent_issue")
	issue_json=$(gh api "$issue_api" 2>/dev/null) || issue_json=""
	if [[ -z "$issue_json" ]]; then
		return 0
	fi
	local _RS=$'\x1e'
	IFS="$_RS" read -r -d '' issue_body issue_labels < <(
		printf '%s' "$issue_json" | jq -j --arg rs "$_RS" \
			'(.body // ""), $rs, ([.labels[]?.name] | join(",")), "\u0000"'
	) || true

	if ! _pm_issue_needs_partial_closeout "$issue_body" "$issue_labels"; then
		return 0
	fi

	dedup_count=$(gh api "${issue_api}/comments" 2>/dev/null | jq --arg marker "PARTIAL_PARENT_CLOSEOUT:PR#${pr_number}" '[.[] | select(.body | contains($marker))] | length' 2>/dev/null) || dedup_count=0
	[[ "$dedup_count" =~ ^[0-9]+$ ]] || dedup_count=0
	if [[ "$dedup_count" -gt 0 ]]; then
		echo "[pulse-wrapper] Deterministic merge: skipped duplicate partial parent closeout on #${parent_issue} for PR #${pr_number} (GH#23937)" >>"$LOGFILE"
		return 0
	fi

	followups=$(_pm_unmet_acceptance_criteria "$issue_body")
	delivered_body="${merge_summary:-PR #${pr_number} merged as a leaf delivery.}"

	local partial_comment
	partial_comment="<!-- PARTIAL_PARENT_CLOSEOUT:PR#${pr_number} -->
## Partial Parent Closeout

PR #${pr_number} merged against this broad parent using a non-closing \`For #${parent_issue}\` / \`Ref #${parent_issue}\` reference, so the parent remains open.

### Delivered

${delivered_body}

### Follow-ups still requiring closure or child issues

${followups}

### Closeout rule

Do not close this parent until the remaining acceptance criteria are covered by merged release evidence or an explicit maintainer/operator closeout decision is posted."

	gh_issue_comment "$parent_issue" --repo "$repo_slug" --body "$partial_comment" 2>/dev/null || true
	echo "[pulse-wrapper] Deterministic merge: posted partial parent closeout on issue #${parent_issue} for PR #${pr_number} (GH#23937)" >>"$LOGFILE"
	return 0
}

_pm_close_primary_linked_issue() {
	local pr_number="$1"
	local repo_slug="$2"
	local linked_issue="$3"
	local closing_comment="$4"
	local labels_supplied="$5"

		# t2099 / GH#19032: parent-task close guard. Parent roadmap issues must
		# stay open until ALL phase children merge (t2046). The PR-body keyword
		# guard prevents workers from writing Closes/Resolves/Fixes against a
		# parent, and they instead use "For #NNN" / "Ref #NNN". Keep this
		# independent metadata guard as defence in depth in case a parent PR body
		# accidentally contains a native closing clause.
		#
		# Behaviour:
		#   - Still post the closing comment (it doubles as a phase-merged
		#     status update on the parent).
		#   - SKIP the `gh issue close` call.
		#   - SKIP fast_fail_reset and unlock (both tied to closing).
		_parent_task_guard=0
		local _pm_li_api
		_pm_li_api=$(_pm_issue_api "$repo_slug" "$linked_issue")
		_linked_labels=$(gh api "${_pm_li_api}" \
			--jq '[.labels[].name] | join(",")' 2>/dev/null) || _linked_labels=""
		if [[ ",${_linked_labels}," == *"${_PM_PARENT_TASK_LABEL_NEEDLE}"* ]]; then
			_parent_task_guard=1
			echo "[pulse-wrapper] Deterministic merge: skipping close of parent-task issue #${linked_issue} (PR #${pr_number} is a phase child; parent stays open until all phases merge) — t2099/GH#19032" >>"$LOGFILE"
		fi

		# Dedup guard: skip if closing comment for this PR already exists (GH#18098).
		local _dedup_count
		_dedup_count=$(gh api "${_pm_li_api}/comments" \
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
			if [[ "$labels_supplied" -eq 0 ]]; then
				pr_labels=$(gh_pr_view "$pr_number" --repo "$repo_slug" \
					--json labels --jq '[.labels[].name] | join(",")' 2>/dev/null) || pr_labels=""
			fi
			local _solved_actor=""
			_solved_actor=$(solved_actor_from_pr_labels "$pr_labels") || _solved_actor=""
			[[ -n "$_solved_actor" ]] && set_solved_label "$linked_issue" "$repo_slug" "$_solved_actor" || true
			clear_terminal_issue_dispatch_labels "$linked_issue" "$repo_slug" "post-merge-pr-${pr_number}" || true
			if _gh_with_timeout write gh issue close "$linked_issue" --repo "$repo_slug" 2>/dev/null; then
				# Closing is not a status transition in GitHub's label model. Converge
				# explicitly so a merged issue cannot remain dashboard-visible as
				# available, queued, claimed, in-progress, or in-review.
				set_issue_status "$linked_issue" "$repo_slug" "done" || true
				reconcile_dependants_after_verified_closure "$repo_slug" "$linked_issue" || true
			fi
			# Reset fast-fail counter now that the issue is resolved (GH#2076)
			fast_fail_reset "$linked_issue" "$repo_slug" || true
			# t1934: Unlock the issue (locked at dispatch time)
			unlock_issue_after_worker "$linked_issue" "$repo_slug"
		fi
	return 0
}

_pm_close_superseded_original_issue() {
	local pr_number="$1"
	local repo_slug="$2"
	local linked_issue="$3"
	local closing_comment="$4"
	local _superseded_original_issue
	_superseded_original_issue=$(_pm_resolve_superseded_original_issue \
		"$pr_number" "$repo_slug" "$linked_issue") || _superseded_original_issue=""
	if [[ -n "$_superseded_original_issue" ]]; then
			local _sup_api _sup_labels _sup_parent_guard=0 _sup_dedup_count
			_sup_api=$(_pm_issue_api "$repo_slug" "$_superseded_original_issue")
			_sup_labels=$(gh api "${_sup_api}" \
				--jq '[.labels[].name] | join(",")' 2>/dev/null) || _sup_labels=""
			if [[ ",${_sup_labels}," == *"${_PM_PARENT_TASK_LABEL_NEEDLE}"* ]]; then
				_sup_parent_guard=1
				echo "[pulse-wrapper] Deterministic merge: skipping close of parent-task original issue #${_superseded_original_issue} via superseded PR #${linked_issue} (merged PR #${pr_number}) — GH#22964" >>"$LOGFILE"
			fi

			_sup_dedup_count=$(gh api "${_sup_api}/comments" \
				2>/dev/null | jq --arg prnum "PR #${pr_number}" \
				'[.[] | select(.body | contains($prnum))] | length' 2>/dev/null) || _sup_dedup_count=0
			[[ "$_sup_dedup_count" =~ ^[0-9]+$ ]] || _sup_dedup_count=0
			if [[ "$_sup_dedup_count" -gt 0 ]]; then
				echo "[pulse-wrapper] Deterministic merge: skipped duplicate closing comment on original issue #${_superseded_original_issue} via superseded PR #${linked_issue} — PR #${pr_number} already referenced (GH#22964)" >>"$LOGFILE"
			else
				gh_issue_comment "$_superseded_original_issue" --repo "$repo_slug" \
					--body "$closing_comment" 2>/dev/null || true
			fi

			if [[ "$_sup_parent_guard" -eq 0 ]]; then
				local _sup_solved_actor=""
				_sup_solved_actor=$(solved_actor_from_pr_labels "$pr_labels") || _sup_solved_actor=""
				[[ -n "$_sup_solved_actor" ]] && set_solved_label "$_superseded_original_issue" "$repo_slug" "$_sup_solved_actor" || true
				clear_terminal_issue_dispatch_labels "$_superseded_original_issue" "$repo_slug" "post-merge-superseded-pr-${pr_number}" || true
				if _gh_with_timeout write gh issue close "$_superseded_original_issue" --repo "$repo_slug" 2>/dev/null; then
					set_issue_status "$_superseded_original_issue" "$repo_slug" "done" || true
					reconcile_dependants_after_verified_closure "$repo_slug" "$_superseded_original_issue" || true
				fi
				fast_fail_reset "$_superseded_original_issue" "$repo_slug" || true
				unlock_issue_after_worker "$_superseded_original_issue" "$repo_slug"
			fi
	fi
	return 0
}
