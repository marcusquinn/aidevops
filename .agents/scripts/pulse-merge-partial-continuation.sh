#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# pulse-merge-partial-continuation.sh — GH#34312: return a worker's merged
# non-closing partial target to the dispatch queue.
#
# A worker that delivers part of an issue opens a ready PR with a non-closing
# `For #N` reference. While that PR is open the worker lifecycle keeps #N
# status:in-review, runner-assigned and without auto-dispatch so no competing
# worker launches (GH#33115, GH#33287). After the pulse merges the PR, nothing
# owns #N any more. Without this step the issue stays in review indefinitely,
# its continuation never dispatches, and phase dependants stay status:blocked
# behind it.
#
# Sourced by pulse-merge.sh, which provides _extract_linked_issue,
# _extract_pr_work_issue and _pm_issue_api. shared-constants.sh provides
# gh_pr_view, gh_issue_comment and set_issue_status. Every helper fails
# closed: unreadable or ambiguous metadata means no write.

[[ -n "${_PULSE_MERGE_PARTIAL_CONTINUATION_LOADED:-}" ]] && return 0
_PULSE_MERGE_PARTIAL_CONTINUATION_LOADED=1

# Trusted coordination events, matching pr-checkpoint-target-lib.sh plus the
# dispatch lease lifecycle. The newest event must show that the worker run
# ended (claim release or terminal lease) before the issue changes owner.
# worker_ownership_lost is excluded: that release preserves a live owner.
_PMPC_EVENT_PATTERN='(^|\n)(CLAIM_RELEASED reason=|DISPATCH_CLAIM |DISPATCH_LEASE phase=|Dispatching worker|(> )?Interactive session claimed)'
_PMPC_MARKER_KIND="merged-partial-continuation"
# Any GitHub closing reference: a closing keyword, optionally followed by a
# colon, then #N, GH-N, owner/repo#N or an issue URL. _extract_linked_issue
# recognises only `keyword #N` separated by whitespace.
_PMPC_CLOSING_REF_PATTERN='(^|[^a-z0-9_])(close[ds]?|fix(es|ed)?|resolve[ds]?)[\s:]+(#[0-9]+|gh-[0-9]+|[a-z0-9_.-]+/[a-z0-9_.-]+#[0-9]+|https?://github\.com/[a-z0-9_.-]+/[a-z0-9_.-]+/issues/[0-9]+)'
# jq definitions shared by every issue-comment reader. `comments` accepts one
# page or `gh api --paginate --slurp` pages and fails when any entry's
# coordination fields cannot be read: a null body is empty text, a missing
# body, association or timestamp is unreadable.
_PMPC_COMMENTS_JQ_DEFS='
	def trusted: .author_association | . == "OWNER" or . == "MEMBER" or . == "COLLABORATOR";
	def readable_comment: (type == "object")
		and ((.author_association | type) == "string")
		and ((.created_at | type) == "string")
		and has("body") and (.body | type | . == "string" or . == "null");
	def comments: if type != "array" then error("unreadable comments")
		elif (.[0]? | type) == "array" then [.[][]] else . end
		| if all(.[]; readable_comment) then . else error("unreadable comment") end;
'

#######################################
# Bounded GitHub read: use the shared timeout wrapper when it is loaded.
# Args: gh arguments
# Returns: gh exit code
#######################################
_pmpc_gh_read() {
	if declare -F _gh_with_timeout >/dev/null 2>&1; then
		_gh_with_timeout read gh "$@"
		return $?
	fi
	gh "$@"
	return $?
}

#######################################
# Confirm the merge from an uncached REST read before releasing the issue.
# Post-merge actions also run on the "Merge already in progress" path, before
# GitHub confirms the merge; an unmerged PR still owns its in-review target.
# Args: $1=repo slug, $2=PR number
# Stdout: PR author login (empty for a deleted account)
# Returns: 0 when the PR is merged, 1 when unmerged or unreadable
#######################################
_pmpc_merged_pr_author() {
	local repo_slug="$1"
	local pr_number="$2"
	local pr_json="" verdict=""
	pr_json=$(_pmpc_gh_read api "repos/${repo_slug}/pulls/${pr_number}" 2>/dev/null) || return 1
	verdict=$(printf '%s' "$pr_json" | jq -r '
		if (type == "object") and (.merged == true) then "merged:" + (.user.login // "")
		else "unmerged" end
	' 2>/dev/null) || return 1
	case "$verdict" in
	merged:*)
		printf '%s' "${verdict#merged:}"
		return 0
		;;
	esac
	return 1
}

#######################################
# Test for a label on the referenced issue.
# Args: $1=issue JSON, $2=label name
# Returns: 0 when present, 1 when absent or unreadable
#######################################
_pmpc_issue_has_label() {
	local issue_json="$1"
	local label_name="$2"
	printf '%s' "$issue_json" | jq -e --arg label "$label_name" '
		any(.labels[]?; (if type == "string" then . else (.name // "") end) == $label)
	' >/dev/null 2>&1
	return $?
}

#######################################
# Classify the referenced issue from its REST JSON.
# Eligible: an open issue (not a PR) whose only lifecycle label is
# status:in-review and that carries no protective hold label.
# Args: $1=issue JSON
# Stdout: "leaf" or "parent"
# Returns: 0 when eligible, 1 otherwise
#######################################
_pmpc_issue_scope() {
	local issue_json="$1"
	local scope=""
	scope=$(printf '%s' "$issue_json" | jq -r '
		def names: [.labels[]? | if type == "string" then . else (.name // empty) end];
		def statuses: [names[] | select(startswith("status:"))];
		def protected: names | any(
			. == "hold-for-review" or . == "no-auto-dispatch" or
			. == "needs-maintainer-review" or . == "needs-maintainer-permissions" or
			. == "persistent"
		);
		if (.pull_request != null) or (((.state // "") | ascii_downcase) != "open") then "ineligible"
		elif (statuses != ["status:in-review"]) or protected then "ineligible"
		elif (names | index("parent-task")) != null then "parent"
		else "leaf" end
	' 2>/dev/null) || return 1
	case "$scope" in
	leaf | parent)
		printf '%s' "$scope"
		return 0
		;;
	esac
	return 1
}

#######################################
# Resolve the runner whose finished run still owns the issue.
# The newest trusted coordination event must be a claim release or a terminal
# dispatch lease; any later dispatch, lease or interactive claim means another
# owner is live. A continuation marker for this PR means the work was done.
# Args: $1=comments JSON (one page or `gh api --paginate --slurp` pages),
#       $2=merged PR number
# Stdout: runner login (runner= field of CLAIM_RELEASED, else comment author)
# Returns: 0 when a finished worker run is the newest owner, 1 otherwise
#          (including any unreadable comment entry)
#######################################
_pmpc_release_owner_from_comments() {
	local comments_json="$1"
	local pr_number="$2"
	local verdict=""
	verdict=$(printf '%s' "$comments_json" | jq -r \
		--arg pattern "$_PMPC_EVENT_PATTERN" \
		--arg marker "kind=${_PMPC_MARKER_KIND} pr=${pr_number} " "${_PMPC_COMMENTS_JQ_DEFS}"'
		[comments[] | select(trusted)] as $trusted
		| if any($trusted[]; (.body // "") | contains($marker)) then "marker"
		else
			[$trusted[] | select((.body // "") | test($pattern))
				| {body: (.body // ""), login: (.user.login // ""),
					created_at: .created_at, id: ((.id // 0) | tonumber? // 0)}]
			| sort_by(.created_at, .id) | last
			| if . == null then "none"
			elif (.body | test("(^|\n)CLAIM_RELEASED reason=worker_ownership_lost([^A-Za-z0-9_]|$)")) then "live"
			elif (.body | test("(^|\n)CLAIM_RELEASED reason=")) then
				"released:" + (((.body | capture("(^|\n)CLAIM_RELEASED reason=[^\n]* runner=(?<runner>[A-Za-z0-9._-]+(\\[bot\\])?)") | .runner) // .login))
			elif (.body | test("(^|\n)DISPATCH_LEASE phase=terminal ")) then "released:" + .login
			else "live" end
		end
	' 2>/dev/null) || return 1
	case "$verdict" in
	released:?*)
		printf '%s' "${verdict#released:}"
		return 0
		;;
	esac
	return 1
}

#######################################
# Require every assignee to be the finished runner or the merged PR author.
# Args: $1=issue JSON, $2=runner login, $3=PR author login (may be empty)
# Stdout: comma-separated assignees to release (empty when unassigned)
# Returns: 0 when owned, 1 when a foreign assignee exists or the assignee
#          list or any entry's login is unreadable
#######################################
_pmpc_owned_assignees() {
	local issue_json="$1"
	local runner_login="$2"
	local pr_author="$3"
	local assignees=""
	assignees=$(printf '%s' "$issue_json" | jq -r --arg runner "$runner_login" --arg author "$pr_author" '
		if (.assignees | type) != "array" then error("unreadable assignees") else . end
		| [.assignees[] | if (type == "object") and ((.login | type) == "string") and (.login != "")
			then .login else error("unreadable assignee") end] as $logins
		| if all($logins[]; (. == $runner and $runner != "") or (. == $author and $author != ""))
		then ($logins | join(",")) else error("foreign assignee") end
	' 2>/dev/null) || return 1
	printf '%s' "$assignees"
	return 0
}

#######################################
# Detect another open PR that still owns the issue's in-review state.
# Reads every open PR body with complete REST pagination rather than a text
# search, whose matching of owner/repo#N and URL forms is not a documented
# contract. A reference is a closing or For/Ref keyword followed by #N, GH-N,
# the same repository's owner/repo#N, or its issues/N URL. A null body is an
# empty PR description; a missing number or body field is unreadable.
# Args: $1=repo slug, $2=issue number, $3=merged PR number
# Returns: 0 when another open PR references the issue, the read fails or an
#          entry is unreadable (fail closed), 1 when no other open PR
#          references it
#######################################
_pmpc_other_open_pr_owns_issue() {
	local repo_slug="$1"
	local issue_num="$2"
	local merged_pr="$3"
	local prs_json="" count=""
	prs_json=$(_pmpc_gh_read api "repos/${repo_slug}/pulls?state=open&per_page=100" \
		--paginate --slurp 2>/dev/null) || return 0
	count=$(printf '%s' "$prs_json" | jq -r --arg num "$issue_num" --arg merged "$merged_pr" \
		--arg slug "$repo_slug" '
		($slug | gsub("[.]"; "\\.")) as $slug_re
		| ("(^|[^a-z0-9_])(close[ds]?|fix(es|ed)?|resolve[ds]?|for|ref)[\\s:]+(("
			+ $slug_re + ")?#|gh-|https?://github\\.com/" + $slug_re + "/issues/)"
			+ $num + "([^0-9]|$)") as $reference
		| if type != "array" then error("unexpected PR list shape")
		elif (.[0]? | type) == "array" then [.[][]] else . end
		| if any(.[]; (type != "object") or ((.number | type) != "number")
			or (has("body") | not) or ((.body | type) as $t | $t != "string" and $t != "null"))
		then error("unreadable PR entry")
		else [.[] | select((.number | tostring) != $merged)
			| select((.body // "") | test($reference; "i"))]
			| length end
	' 2>/dev/null) || return 0
	[[ "$count" =~ ^[0-9]+$ ]] || return 0
	[[ "$count" -gt 0 ]] && return 0
	return 1
}

#######################################
# Detect any closing reference in the merged PR's body, including the forms
# _extract_linked_issue does not parse (`Closes: #N`, GH-N, owner/repo#N, an
# issue URL). GitHub closes those targets on merge, so such a PR completes
# work rather than delivering a partial.
# Args: $1=PR number, $2=repo slug
# Returns: 0 when a closing reference exists or the body is unreadable (fail
#          closed), 1 when the body has none
#######################################
_pmpc_pr_body_has_closing_ref() {
	local pr_number="$1"
	local repo_slug="$2"
	local pr_body="" verdict=""
	pr_body=$(gh_pr_view "$pr_number" --repo "$repo_slug" --json body --jq '.body // ""' 2>/dev/null) || return 0
	verdict=$(printf '%s' "$pr_body" | jq -Rrs --arg pattern "$_PMPC_CLOSING_REF_PATTERN" \
		'test($pattern; "i")' 2>/dev/null) || return 0
	[[ "$verdict" == "false" ]] && return 1
	return 0
}

#######################################
# Build the audit comment for a restored continuation.
# Args: $1=merged PR number, $2=issue number, $3=scope (leaf|parent)
# Stdout: comment body
# Returns: 0
#######################################
_pmpc_comment_body() {
	local pr_number="$1"
	local issue_num="$2"
	local scope="$3"
	local restored="status:available and auto-dispatch"
	[[ "$scope" == "parent" ]] && restored="status:available (parent-task tracker, so no auto-dispatch)"
	printf '%s\n' "<!-- ops:start — workers: skip this comment, it is audit trail not implementation context -->
<!-- aidevops:ops kind=${_PMPC_MARKER_KIND} pr=${pr_number} -->
Partial PR #${pr_number} merged with a non-closing \`For\`/\`Ref #${issue_num}\` reference, so this issue stays open. The worker's in-review handoff no longer owns an open PR: restored ${restored} and released the runner assignment, so the next worker continues from the brief's ledger.
<!-- ops:end -->"
	return 0
}

#######################################
# Post the audit comment, retrying once when the first attempt did not land.
# A failed write can still have landed (timeout after the write), so the retry
# first re-reads the comments: an existing marker counts as posted, and an
# unreadable list skips the retry rather than risk a second marker.
# Args: $1=repo slug, $2=issue number, $3=merged PR number, $4=scope
# Returns: 0 when the marker comment exists, 1 otherwise
#######################################
_pmpc_post_audit_comment() {
	local repo_slug="$1"
	local issue_num="$2"
	local pr_number="$3"
	local scope="$4"
	local body="" comments_json="" verdict=""
	body=$(_pmpc_comment_body "$pr_number" "$issue_num" "$scope")
	if gh_issue_comment "$issue_num" --repo "$repo_slug" --body "$body" >/dev/null 2>&1; then
		return 0
	fi
	comments_json=$(_pmpc_gh_read api "$(_pm_issue_api "$repo_slug" "$issue_num")/comments?per_page=100" \
		--paginate --slurp 2>/dev/null) || return 1
	verdict=$(printf '%s' "$comments_json" | jq -r \
		--arg marker "kind=${_PMPC_MARKER_KIND} pr=${pr_number} " "${_PMPC_COMMENTS_JQ_DEFS}"'
		[comments[] | select(trusted) | (.body // "") | contains($marker)]
		| if any then "present" else "absent" end
	' 2>/dev/null) || return 1
	[[ "$verdict" == "present" ]] && return 0
	[[ "$verdict" == "absent" ]] || return 1
	if gh_issue_comment "$issue_num" --repo "$repo_slug" --body "$body" >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

#######################################
# Project the continuation state and record the audit comment.
# Args: $1=repo slug, $2=issue number, $3=scope (leaf|parent),
#       $4=comma-separated assignees to release, $5=merged PR number,
#       $6=1 when a parent tracker still carries auto-dispatch (default 0)
# Returns: 0 when the status transition succeeded, 1 otherwise
#######################################
_pmpc_project_available() {
	local repo_slug="$1"
	local issue_num="$2"
	local scope="$3"
	local assignees="$4"
	local pr_number="$5"
	local parent_has_dispatch="${6:-0}"
	local login="" dispatch_note="unchanged"
	local -a transition_args=()
	local -a logins=()

	if [[ -n "$assignees" ]]; then
		IFS=',' read -r -a logins <<<"$assignees"
		for login in "${logins[@]}"; do
			[[ -n "$login" ]] && transition_args+=(--remove-assignee "$login")
		done
	fi
	if [[ "$scope" == "leaf" ]]; then
		transition_args+=(--add-label "auto-dispatch")
		dispatch_note="added"
	elif [[ "$parent_has_dispatch" == "1" ]]; then
		# A parent-task tracker is never dispatch-eligible; leave it without auto-dispatch.
		transition_args+=(--remove-label "auto-dispatch")
		dispatch_note="removed"
	fi
	if ! set_issue_status "$issue_num" "$repo_slug" available \
		${transition_args[@]+"${transition_args[@]}"} >/dev/null 2>&1; then
		echo "[pulse-wrapper] Deterministic merge: failed to return #${issue_num} to the queue after partial PR #${pr_number} (GH#34312)" >>"$LOGFILE"
		return 1
	fi
	if ! _pmpc_post_audit_comment "$repo_slug" "$issue_num" "$pr_number" "$scope"; then
		echo "[pulse-wrapper] Deterministic merge: returned #${issue_num} to the queue after partial PR #${pr_number} but the audit comment failed and no retry confirmed it, so the continuation marker is missing (GH#34312)" >>"$LOGFILE"
	fi
	echo "[pulse-wrapper] Deterministic merge: returned #${issue_num} to status:available (auto-dispatch ${dispatch_note}, released: ${assignees:-none}) after partial PR #${pr_number} (GH#34312)" >>"$LOGFILE"
	return 0
}

#######################################
# Return a worker's merged non-closing partial target to the dispatch queue.
#
# Fires only for a confirmed-merged origin:worker / origin:worker-takeover PR
# that closes no issue in any GitHub reference form and whose single explicit
# For/Ref issue is open, status:in-review, unprotected, owned only by the
# finished worker run, and not referenced by another open PR. Leaves regain
# auto-dispatch; parent-task trackers end without it.
#
# Args: $1=merged PR number, $2=repo slug, $3=closing target (empty for
#       non-closing partials), $4=PR labels CSV (fetched when empty)
# Returns: 0 always (best-effort post-merge hygiene)
#######################################
_pm_restore_partial_continuation() {
	local pr_number="$1"
	local repo_slug="$2"
	local linked_issue="${3:-}"
	local pr_labels="${4:-}"
	local closing="" target="" issue_api="" issue_json="" scope="" comments_json=""
	local runner_login="" pr_author="" assignees="" parent_has_dispatch=0

	[[ -z "$linked_issue" && "$pr_number" =~ ^[0-9]+$ && "$repo_slug" == */* ]] || return 0
	if [[ -z "$pr_labels" ]]; then
		pr_labels=$(gh_pr_view "$pr_number" --repo "$repo_slug" --json labels \
			--jq '[.labels[].name] | join(",")' 2>/dev/null) || return 0
	fi
	[[ ",${pr_labels}," == *",origin:worker,"* || ",${pr_labels}," == *",origin:worker-takeover,"* ]] || return 0
	# An empty caller target can also mean the upstream closing-target read
	# failed, and the explicit resolver returns a closing target first. Prove
	# independently that the PR closes nothing before using its For/Ref target.
	closing=$(_extract_linked_issue "$pr_number" "$repo_slug" 2>/dev/null) || return 0
	[[ -z "$closing" ]] || return 0
	if _pmpc_pr_body_has_closing_ref "$pr_number" "$repo_slug"; then
		echo "[pulse-wrapper] Deterministic merge: no partial continuation for PR #${pr_number} — body closes an issue or is unreadable (GH#34312)" >>"$LOGFILE"
		return 0
	fi
	target=$(_extract_pr_work_issue "$pr_number" "$repo_slug" explicit 2>/dev/null) || return 0
	[[ "$target" =~ ^[0-9]+$ ]] || return 0
	if ! pr_author=$(_pmpc_merged_pr_author "$repo_slug" "$pr_number"); then
		echo "[pulse-wrapper] Deterministic merge: kept #${target} in review after partial PR #${pr_number} — merge not confirmed by a fresh PR read (GH#34312)" >>"$LOGFILE"
		return 0
	fi

	issue_api=$(_pm_issue_api "$repo_slug" "$target")
	issue_json=$(_pmpc_gh_read api "$issue_api" 2>/dev/null) || return 0
	scope=$(_pmpc_issue_scope "$issue_json") || return 0
	comments_json=$(_pmpc_gh_read api "${issue_api}/comments?per_page=100" --paginate --slurp 2>/dev/null) || return 0
	if ! runner_login=$(_pmpc_release_owner_from_comments "$comments_json" "$pr_number"); then
		echo "[pulse-wrapper] Deterministic merge: kept #${target} in review after partial PR #${pr_number} — newest owner is not a finished worker run or continuation already recorded (GH#34312)" >>"$LOGFILE"
		return 0
	fi
	if ! assignees=$(_pmpc_owned_assignees "$issue_json" "$runner_login" "$pr_author"); then
		echo "[pulse-wrapper] Deterministic merge: kept #${target} in review after partial PR #${pr_number} — assignee is not the finished runner (GH#34312)" >>"$LOGFILE"
		return 0
	fi
	if _pmpc_other_open_pr_owns_issue "$repo_slug" "$target" "$pr_number"; then
		echo "[pulse-wrapper] Deterministic merge: kept #${target} in review after partial PR #${pr_number} — another open PR references it or PR lookup failed (GH#34312)" >>"$LOGFILE"
		return 0
	fi
	if [[ "$scope" == "parent" ]] && _pmpc_issue_has_label "$issue_json" "auto-dispatch"; then
		parent_has_dispatch=1
	fi
	_pmpc_project_available "$repo_slug" "$target" "$scope" "$assignees" "$pr_number" "$parent_has_dispatch" || true
	return 0
}
