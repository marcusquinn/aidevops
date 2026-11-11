#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# pr-checkpoint-terminal-action.sh — GH#37779: bounded terminal action for a
# stalled worker draft checkpoint that Pulse can no longer continue.
#
# While an origin:worker draft is open, WORKER_DRAFT_CHECKPOINT blocks ordinary
# redispatch of its issue. Once the per-PR fuse is reached, or the exact-head
# target is confirmed ineligible, no automatic continuation can lift that
# block, and drafts stayed held for days. After the brief owner's window
# (AIDEVOPS_PCC_TERMINAL_ACTION_SECONDS, default 12h after the newest attention
# record or stall release) this takes exactly one terminal action per PR head:
#
#   - land: an additive (no removed files), mergeable, non-closing `For #N`
#     checkpoint whose reported checks all succeeded is marked ready for
#     review, so the existing guarded Pulse merge pass (review bot, CI,
#     author trust, closure checks) lands it as a partial checkpoint. The
#     issue stays open and ordinary dispatch continues from the default branch;
#   - close: any other eligible draft is closed with a pointer comment. The
#     branch is kept, and the issue records it so the next worker can salvage it.
#
# Every write requires fresh evidence; anything unreadable, pending or
# protected means no write (fail closed):
#   - the exact head, open origin:worker draft, no protective PR label
#     (_pr_checkpoint_pr_metadata_is_eligible);
#   - an open, unassigned status:available issue without hold-for-review,
#     no-auto-dispatch, needs-maintainer-*, persistent or parent-task labels,
#     and without a pr-only completion contract;
#   - the stall release that paused the head is still the newest trusted
#     ownership event (no newer claim, lease or interactive claim);
#   - no terminal record already exists for this PR head;
#   - checks and mergeability are terminal; pending state defers the action.
#
# Sourced by pr-checkpoint-continuation-helper.sh, which provides
# _PCC_JQ_RELEASE_DEFS, _pcc_issue_comments and _pcc_login_is_safe;
# pr-checkpoint-target-lib.sh provides the PR/link predicates.

[[ -n "${_PR_CHECKPOINT_TERMINAL_ACTION_LOADED:-}" ]] && return 0
_PR_CHECKPOINT_TERMINAL_ACTION_LOADED=1

_PCC_TERMINAL_MARKER="aidevops:stalled-checkpoint-terminal"
# 0 disables the terminal action; the hold then stays a permanent stop.
_PCC_TERMINAL_ACTION_SECONDS="${AIDEVOPS_PCC_TERMINAL_ACTION_SECONDS:-43200}"
[[ "$_PCC_TERMINAL_ACTION_SECONDS" =~ ^[0-9]{1,10}$ ]] || _PCC_TERMINAL_ACTION_SECONDS=43200
_PCC_TERMINAL_ACTION_SECONDS=$((10#$_PCC_TERMINAL_ACTION_SECONDS))
((_PCC_TERMINAL_ACTION_SECONDS < 2147483648)) || _PCC_TERMINAL_ACTION_SECONDS=43200
_PCC_PR_ONLY_CONTRACT_MARKER="aidevops:completion-contract:pr-only"

#######################################
# Decide whether the brief owner's window has passed: measured from the newer
# of the head's attention record and the stall release that paused it.
# Args: $1=newest attention epoch (0 when none), $2=release epoch
# Returns: 0 when the terminal action is due, 1 otherwise (or disabled)
#######################################
_pcc_terminal_action_due() {
	local attention_epoch="$1" release_epoch="$2"
	local anchor=0 now=""
	[[ "$_PCC_TERMINAL_ACTION_SECONDS" -gt 0 ]] || return 1
	[[ "$attention_epoch" =~ ^[0-9]{1,12}$ && "$release_epoch" =~ ^[0-9]{1,12}$ ]] || return 1
	anchor="$attention_epoch"
	((release_epoch <= anchor)) || anchor="$release_epoch"
	((anchor > 0)) || return 1
	now=$(date +%s) || return 1
	[[ "$now" =~ ^[0-9]+$ ]] || return 1
	((now - anchor >= _PCC_TERMINAL_ACTION_SECONDS)) || return 1
	return 0
}

#######################################
# Classify the PR's reported checks.
# Args: $1=PR JSON with statusCheckRollup
# Output: success | pending | failure (no reported checks is success: the
#         merge pass applies the repository's own required-check gates)
# Returns: 0 when classified, 1 when unreadable
#######################################
_pcc_terminal_checks_state() {
	local pr_json="$1"
	jq -er '
		(.statusCheckRollup // []) as $checks |
		if ($checks | type) != "array" then error("unreadable checks") else . end |
		def pending: if .__typename == "StatusContext" or has("state")
			then ((.state // "") | ascii_upcase) as $s | ($s == "PENDING" or $s == "EXPECTED" or $s == "")
			else ((.status // "") | ascii_upcase) != "COMPLETED" end;
		def passed: if .__typename == "StatusContext" or has("state")
			then ((.state // "") | ascii_upcase) == "SUCCESS"
			else ((.conclusion // "") | ascii_upcase) as $c | ($c == "SUCCESS" or $c == "NEUTRAL" or $c == "SKIPPED") end;
		if any($checks[]; pending) then "pending"
		elif all($checks[]; passed) then "success"
		else "failure" end
	' <<<"$pr_json" 2>/dev/null || return 1
	return 0
}

#######################################
# Report whether the PR only adds or modifies files (no removed files).
# Args: $1=repo slug, $2=PR number
# Returns: 0 additive, 1 removes files, 2 unreadable
#######################################
_pcc_terminal_pr_additive() {
	local repo="$1" pr="$2" files="" removed=""
	files=$(gh api "repos/${repo}/pulls/${pr}/files?per_page=100" --paginate --slurp 2>/dev/null) || return 2
	# Not jq -e: the additive answer is `false`, which -e reports as failure.
	removed=$(jq -r 'if type != "array" then error("unreadable file pages") else flatten end |
		if all(.[]; type == "object" and (.status | type) == "string") then . else error("unreadable file entry") end |
		any(.[]; .status == "removed" or .status == "renamed")' <<<"$files" 2>/dev/null) || return 2
	[[ "$removed" == true || "$removed" == false ]] || return 2
	[[ "$removed" == false ]] || return 1
	return 0
}

#######################################
# Verify the issue still allows a terminal action.
# Args: $1=issue JSON (REST)
# Returns: 0 eligible, 1 otherwise
#######################################
_pcc_terminal_issue_eligible() {
	local issue_json="$1"
	jq -e --arg pr_only "$_PCC_PR_ONLY_CONTRACT_MARKER" --arg hold "$_PCTL_HOLD_LABEL" '
		def names: [.labels[]? | if type == "string" then . else (.name // empty) end];
		(((.state // "") | ascii_downcase) == "open") and ((.pull_request // null) == null) and
		(((.assignees // []) | length) == 0) and
		([names[] | select(startswith("status:"))] == ["status:available"]) and
		(names | any(. == $hold or . == "no-auto-dispatch" or startswith("needs-maintainer-") or
			. == "persistent" or . == "parent-task" or . == "blocked" or . == "on hold") | not) and
		(((.body // "") | contains($pr_only)) | not)
	' <<<"$issue_json" >/dev/null 2>&1 || return 1
	return 0
}

#######################################
# Verify the stall release that paused the head is still the newest trusted
# ownership event and that no terminal record exists for this PR head.
# Args: $1=comments JSON, $2=trusted logins JSON, $3=release id, $4=marker key
# Output: current | recorded | stale
# Returns: 0 when classified, 1 when unreadable
#######################################
_pcc_terminal_comment_state() {
	local comments="$1" trusted_logins="$2" release_id="$3" key="$4"
	jq -er --argjson trusted_logins "$trusted_logins" --argjson release "$release_id" --arg key "$key" \
		"${_PCC_JQ_RELEASE_DEFS}"'
		[flatten[] | select(trusted_event)] | sort_by(.id) as $c |
		if any($c[]; (.body // "") | contains($key)) then "recorded"
		elif ([$c[] | select(ownership($c))] | last | .id) == $release then "current"
		else "stale" end
	' <<<"$comments" 2>/dev/null || return 1
	return 0
}

#######################################
# Post the issue audit record, outside the ops block for the close pointer.
# Args: repo, issue, pr, head, release id, action, cause, head ref
# Returns: 0 posted, 1 failed
#######################################
_pcc_terminal_post_record() {
	local repo="$1" issue="$2" pr="$3" head="$4" release_id="$5" action="$6" cause="$7" ref="$8"
	local summary="" pointer=""
	if [[ "$action" == ready_for_merge ]]; then
		summary="Draft PR #${pr} was additive, mergeable, non-closing and its checks passed, so Pulse marked it ready for review. The guarded Pulse merge pass lands it as a partial \`For #${issue}\` checkpoint; this issue stays open and ordinary dispatch continues from the default branch."
	else
		summary="Draft PR #${pr} could not be landed as a partial checkpoint, so Pulse closed it and kept its branch. Ordinary dispatch restarts from the current brief."
		pointer="
Preserved checkpoint: branch \`${ref}\` at \`${head}\` (closed draft PR #${pr}). A new worker may salvage commits from it instead of restarting; reopen the PR to continue it instead."
	fi
	local body="<!-- ops:start — workers: skip this comment, it is audit trail not implementation context -->
<!-- ${_PCC_TERMINAL_MARKER} pr=${pr} head=${head} release=${release_id} -->
STALLED_CHECKPOINT_TERMINAL_ACTION pr=${pr} head=${head} action=${action} cause=${cause}

Pulse can no longer continue draft PR #${pr} automatically (\`${cause}\`), and the window for the brief owner has passed without a change. ${summary}

See \`reference/checkpoint-revision-recovery.md\` \"Bounded terminal action\". Posted once per PR head.
<!-- ops:end -->${pointer}"
	gh api "repos/${repo}/issues/${issue}/comments" --method POST --raw-field body="$body" >/dev/null || return 1
	return 0
}

#######################################
# Mark the draft ready, or close it keeping the branch.
# Args: repo, issue, pr, action
# Returns: 0 on success, 1 otherwise
#######################################
_pcc_terminal_apply() {
	local repo="$1" issue="$2" pr="$3" action="$4"
	if [[ "$action" == ready_for_merge ]]; then
		gh pr ready "$pr" --repo "$repo" >/dev/null 2>&1 || return 1
		return 0
	fi
	local comment="Pulse closed this stalled worker draft checkpoint after automatic continuation was exhausted. The branch is kept; issue #${issue} records the pointer, and ordinary dispatch resumes from the current brief. Reopen this PR to continue it instead."
	if declare -F gh_pr_close_safe >/dev/null 2>&1; then
		gh_pr_close_safe "$pr" --repo "$repo" --comment "$comment" >/dev/null 2>&1 || return 1
	else
		gh pr close "$pr" --repo "$repo" --comment "$comment" >/dev/null 2>&1 || return 1
	fi
	return 0
}

#######################################
# Check for a protective maintainer label on a PR snapshot.
# Args: $1=PR JSON. Returns: 0 held, 1 otherwise.
#######################################
_pcc_terminal_pr_held() {
	local pr_json="$1"
	jq -e '[.labels[]? | (.name? // empty) | select(startswith("needs-maintainer-"))] | length > 0' <<<"$pr_json" >/dev/null 2>&1 || return 1
	return 0
}

#######################################
# Fence the terminal write with continuation's distributed claim protocol.
# A subshell isolates the claim library's settings and guarantees claim cleanup.
# Args: repo, issue, pr, head, release id, action, cause, head ref
# Returns: 0 action and audit completed, 1 deferred or failed
#######################################
_pcc_terminal_fenced_apply() (
	local repo="$1" issue="$2" pr="$3" head="$4" release_id="$5" action="$6" cause="$7" ref="$8"
	local runner="" nonce="" claim_id="" claims="" comments="" trusted="" state="" metadata="" expires=""
	# shellcheck source=dispatch-claim-helper.sh
	source "${BASH_SOURCE[0]%/*}/dispatch-claim-helper.sh"
	runner=$(_resolve_runner "") || return 1
	aidevops_can_manage_repo_issue_state "$repo" "$runner" || return 1
	nonce=$(_generate_nonce) || return 1
	claim_id=$(_post_claim "$issue" "$repo" "$runner" "$nonce" "$(_now_utc)" \
		"checkpoint_mode=terminal" "terminal-${pr}") || return 1
	[[ "$claim_id" =~ ^[1-9][0-9]*$ ]] || return 1
	trap '_delete_losing_claim_comment "$repo" "$claim_id"' EXIT
	sleep "$DISPATCH_CLAIM_WINDOW"
	claims=$(_fetch_claims "$issue" "$repo" "$runner") || return 1
	_resolve_claim_race_result "$issue" "$repo" "$runner" "$nonce" "$claim_id" "$claims" >/dev/null || return 1
	# The winning terminal claim alone may explain a new ownership event.
	comments=$(_pcc_issue_comments "$repo" "$issue") &&
		comments=$(jq -c --argjson id "$claim_id" '[flatten[] | select(.id != $id)]' <<<"$comments") &&
		trusted=$(_pr_checkpoint_trusted_logins "$comments" "$repo") &&
		state=$(_pcc_terminal_comment_state "$comments" "$trusted" "$release_id" \
			"<!-- ${_PCC_TERMINAL_MARKER} pr=${pr} head=${head} ") && [[ "$state" == current ]] || return 1
	metadata=$(gh api "repos/${repo}/issues/${issue}") && _pcc_terminal_issue_eligible "$metadata" || return 1
	metadata=$(gh pr view "$pr" --repo "$repo" --json number,state,isDraft,isCrossRepository,headRefOid,headRefName,author,labels,body,closingIssuesReferences) &&
		_pr_checkpoint_pr_metadata_is_eligible "$metadata" "$repo" "$pr" "$issue" "$head" "$ref" "" || return 1
	if _pcc_terminal_pr_held "$metadata"; then
		return 1
	fi
	if _interactive_claim_fence_blocks_dispatch "$issue" "$repo"; then
		return 1
	fi
	if [[ "$action" == close ]]; then
		# Persist salvage context BEFORE closure: a failed post must leave the
		# draft open and retryable, not strand its pointer behind eligibility.
		local pointer="Preserved checkpoint: branch \`${ref}\` at \`${head}\` (draft PR #${pr}). Pulse is preparing to close this stalled checkpoint while keeping its branch. A new worker may salvage these commits; inspect the PR's current state before continuing."
		gh api "repos/${repo}/issues/${issue}/comments" --method POST --raw-field body="$pointer" >/dev/null || return 1
	fi
	# Recheck consensus and remaining lease immediately before the terminal write.
	claims=$(_fetch_claims "$issue" "$repo" "$runner") || return 1
	_resolve_claim_race_result "$issue" "$repo" "$runner" "$nonce" "$claim_id" "$claims" >/dev/null || return 1
	expires=$(jq -er --arg n "$nonce" '.[] | select(.nonce == $n) | .lease_expires_at | numbers' <<<"$claims") || return 1
	((expires > $(_now_epoch) + 60)) || return 1
	_pcc_terminal_apply "$repo" "$issue" "$pr" "$action" || return 1
	[[ "$action" == ready_for_merge ]] || action="closed"
	_pcc_terminal_post_record "$repo" "$issue" "$pr" "$head" "$release_id" "$action" "$cause" "$ref" || {
		printf 'STALLED_CHECKPOINT_TERMINAL_RECORD_FAILED: PR #%s in %s issue=#%s\n' "$pr" "$repo" "$issue"
		return 1
	}
	return 0
)

#######################################
# Take the bounded terminal action for a stalled draft that can no longer be
# continued. Never acts on unreadable, pending or protected state.
# Args: $1=repo slug, $2=issue, $3=PR, $4=exact head SHA, $5=stall release id,
#       $6=cause (per_pr_fuse | target_rejected)
# Output: STALLED_CHECKPOINT_TERMINAL_{ACTION,EXISTS,DEFERRED,SKIPPED} line
# Returns: 0 action taken or already recorded, 1 deferred/skipped/failed
#######################################
_pcc_terminal_checkpoint_action() {
	local repo="$1" issue="$2" pr="$3" head="$4" release_id="$5" cause="$6"
	local pr_json="" issue_json="" comments="" trusted_logins="" state="" checks="" ref=""
	local action="close" mergeable="" merge_state="" additive_rc=0
	local prefix="PR #${pr} in ${repo} head=${head} issue=#${issue}"
	[[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ && "$issue" =~ ^[1-9][0-9]*$ &&
		"$pr" =~ ^[1-9][0-9]*$ && "$head" =~ ^[0-9a-fA-F]{40,64}$ && "$release_id" =~ ^[1-9][0-9]*$ ]] || return 1
	pr_json=$(gh pr view "$pr" --repo "$repo" --json number,state,isDraft,isCrossRepository,headRefOid,headRefName,author,labels,body,closingIssuesReferences,mergeable,mergeStateStatus,statusCheckRollup 2>/dev/null) || {
		printf 'STALLED_CHECKPOINT_TERMINAL_DEFERRED: %s reason=pr_metadata_unavailable\n' "$prefix"
		return 1
	}
	if ! _pr_checkpoint_pr_metadata_is_eligible "$pr_json" "$repo" "$pr" "$issue" "$head" "" "" ||
		_pcc_terminal_pr_held "$pr_json"; then
		printf 'STALLED_CHECKPOINT_TERMINAL_SKIPPED: %s reason=pr_not_eligible\n' "$prefix"
		return 1
	fi
	issue_json=$(gh api "repos/${repo}/issues/${issue}" 2>/dev/null) || {
		printf 'STALLED_CHECKPOINT_TERMINAL_DEFERRED: %s reason=issue_metadata_unavailable\n' "$prefix"
		return 1
	}
	if ! _pcc_terminal_issue_eligible "$issue_json"; then
		printf 'STALLED_CHECKPOINT_TERMINAL_SKIPPED: %s reason=issue_not_eligible\n' "$prefix"
		return 1
	fi
	comments=$(_pcc_issue_comments "$repo" "$issue" 2>/dev/null) &&
		trusted_logins=$(_pr_checkpoint_trusted_logins "$comments" "$repo" 2>/dev/null) &&
		state=$(_pcc_terminal_comment_state "$comments" "$trusted_logins" "$release_id" \
			"<!-- ${_PCC_TERMINAL_MARKER} pr=${pr} head=${head} ") || {
		printf 'STALLED_CHECKPOINT_TERMINAL_DEFERRED: %s reason=issue_comments_unavailable\n' "$prefix"
		return 1
	}
	case "$state" in
	recorded)
		printf 'STALLED_CHECKPOINT_TERMINAL_EXISTS: %s\n' "$prefix"
		return 0
		;;
	current) ;;
	*)
		printf 'STALLED_CHECKPOINT_TERMINAL_SKIPPED: %s reason=newer_coordination\n' "$prefix"
		return 1
		;;
	esac
	checks=$(_pcc_terminal_checks_state "$pr_json") || checks="unreadable"
	mergeable=$(jq -r '.mergeable // "" | ascii_upcase' <<<"$pr_json" 2>/dev/null) || mergeable=""
	merge_state=$(jq -r '.mergeStateStatus // "" | ascii_upcase' <<<"$pr_json" 2>/dev/null) || merge_state=""
	if [[ "$checks" == pending || "$checks" == unreadable || "$mergeable" == UNKNOWN || -z "$mergeable" ||
		"$merge_state" == UNKNOWN || -z "$merge_state" ]]; then
		printf 'STALLED_CHECKPOINT_TERMINAL_DEFERRED: %s reason=checks_or_mergeability_pending checks=%s mergeable=%s merge_state=%s\n' \
			"$prefix" "$checks" "${mergeable:-unknown}" "${merge_state:-unknown}"
		return 1
	fi
	if [[ "$checks" == success && "$mergeable" == MERGEABLE &&
		("$merge_state" == CLEAN || "$merge_state" == DRAFT) ]] &&
		_pr_checkpoint_nonclosing_draft_links_issue "$pr_json" "$issue"; then
		_pcc_terminal_pr_additive "$repo" "$pr" || additive_rc=$?
		if [[ "$additive_rc" -eq 2 ]]; then
			printf 'STALLED_CHECKPOINT_TERMINAL_DEFERRED: %s reason=pr_files_unavailable\n' "$prefix"
			return 1
		fi
		[[ "$additive_rc" -ne 0 ]] || action="ready_for_merge"
	fi
	ref=$(jq -r '.headRefName // ""' <<<"$pr_json" 2>/dev/null) || ref=""
	if ! _pcc_terminal_fenced_apply "$repo" "$issue" "$pr" "$head" "$release_id" "$action" "$cause" "$ref"; then
		printf 'STALLED_CHECKPOINT_TERMINAL_DEFERRED: %s reason=%s_failed\n' "$prefix" "$action"
		return 1
	fi
	[[ "$action" == ready_for_merge ]] || action="closed"
	printf 'STALLED_CHECKPOINT_TERMINAL_ACTION: %s action=%s cause=%s checks=%s mergeable=%s\n' \
		"$prefix" "$action" "$cause" "$checks" "$mergeable"
	return 0
}
