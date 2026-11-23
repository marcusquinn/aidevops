#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Approval-related checkpoint continuation functions; sourced by the orchestrator.

[[ -n "${_PCC_APPROVAL_LOADED:-}" ]] && return 0
_PCC_APPROVAL_LOADED=1

#######################################
# GH#36186: a trusted approval disables the legacy route. Record a failed
# target validation once per head without claiming that approval was consumed:
# deeper permission/metadata checks can fail transiently as well.
# Args: repo, issue, pr, head, release_id, reason, stalls, dedup key,
#       attention_posted (true/false)
# Returns: 0 attention recorded or already present, 1 post failed
#######################################
_pcc_approved_revision_attention() {
	local repo="$1" issue="$2" pr="$3" head="$4" release_id="$5" reason="$6" stalls="$7" key="$8"
	local posted="${9:-false}"
	local pr_json="" issue_json="" comments="" trusted_logins="" diagnostic="" keys="" note="$_PCC_APPROVAL_VALIDATION_NOTE"
	local issue_api="repos/${repo}/issues"
	if [[ "$posted" == true ]]; then
		printf 'STALLED_CHECKPOINT_ATTENTION_EXISTS: PR #%s in %s head=%s\n' "$pr" "$repo" "$head"
		return 0
	fi
	# Re-read the same binding metadata; failure leaves the conservative generic note.
	if pr_json=$(gh pr view "$pr" --repo "$repo" --json number,headRefOid,headRefName,author) &&
		issue_json=$(gh api "${issue_api}/${issue}") &&
		comments=$(_pcc_issue_comments "$repo" "$issue") &&
		trusted_logins=$(_pr_checkpoint_trusted_logins "$comments" "$repo"); then
		diagnostic=$(printf '%s\n' "$pr_json" "$issue_json" "$comments" "$trusted_logins" |
			jq -se --arg repo "$repo" '{repo:$repo,pr:.[0],issue:.[1],comments:.[2],trusted_logins:.[3]}' |
			python3 "$_PR_CHECKPOINT_REVISION_VALIDATOR" binding-diagnostic 2>/dev/null) || diagnostic=""
		if [[ "$diagnostic" =~ ^APPROVAL_BINDING_MISMATCH\ keys=([a-z_,0-9]+)\ approval_comment=[1-9][0-9]*$ ]]; then
			keys="${BASH_REMATCH[1]}"
			note="Mismatched approval binding fields: ${keys}. The existing approval does not match the current target; regenerate it with \`approval-template\`."
			if [[ ",$keys," == *,brief_sha256,* ]]; then
				note="${note} The issue body changed after approval (check for an automated body refresh); regenerate the approval with \`approval-template\`."
			fi
		fi
	fi
	_pcc_post_stall_attention "$repo" "$issue" "$pr" "$head" "$release_id" "$reason" "$stalls" "$key" \
		false "$note" || return 1
	printf 'STALLED_CHECKPOINT_ATTENTION_POSTED: PR #%s in %s head=%s release=%s stalls=%s cause=approved_revision_not_continuable\n' \
		"$pr" "$repo" "$head" "$release_id" "$stalls"
	return 0
}

#######################################
# GH#36186: true when a trusted CHECKPOINT_CONTINUATION_APPROVED comment
# exists (edited or not). Such an approval disables the legacy continuation
# route (_pr_checkpoint_issue_metadata_is_eligible) for the issue.
# GH#37779: only until it expires (_PCTL_APPROVAL_TTL_SECONDS); an expired
# approval no longer owns scheduling, so the legacy re-arm applies again.
# Args: $1=comments JSON (paginated or flat), $2=trusted logins JSON
#######################################
_pcc_comments_have_revision_approval() {
	local comments="$1"
	local trusted_logins="${2:-[]}"
	jq -e --argjson trusted_logins "$trusted_logins" --argjson ttl "$_PCTL_APPROVAL_TTL_SECONDS" \
		"${_PCC_JQ_RELEASE_DEFS}${_PCTL_COORDINATION_JQ_DEFS}"'
		[flatten[] | objects | select(trusted) | .author_association = "MEMBER"] | pctl_approval_owns_scheduling($ttl)
	' <<<"$comments" >/dev/null 2>&1 || return 1
	return 0
}
