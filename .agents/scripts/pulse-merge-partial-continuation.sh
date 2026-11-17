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

# Maximum distance between a DISPATCH_CLAIM ts= and the UTC branch timestamp.
_PMPC_CLAIM_BRANCH_WINDOW_S=600

#######################################
# GH#38042: prove that the PR author's own dispatch claim created this worker
# branch. Branches are feature/auto-<YYYYMMDD>-<HHMMSS>-gh<N> (UTC). The target
# issue must carry a DISPATCH_CLAIM comment written by the author with
# runner=<author>, session=issue-<N> and a ts= within the window.
# Args: $1=repo slug, $2=head ref, $3=author login
# Returns: 0 when a matching claim exists, 1 otherwise or when unreadable
#######################################
_pmpc_branch_claim_matches() {
	local repo_slug="$1" head_ref="$2" author="$3"
	local claims_json
	local stamp="" issue_num="" branch_iso=""
	[[ "$head_ref" =~ ^feature/auto-([0-9]{8})-([0-9]{6})-gh([0-9]+)$ ]] || return 1
	stamp="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
	issue_num="${BASH_REMATCH[3]}"
	[[ "$author" =~ ^[A-Za-z0-9-]+$ ]] || return 1
	branch_iso="${stamp:0:4}-${stamp:4:2}-${stamp:6:2}T${stamp:8:2}:${stamp:10:2}:${stamp:12:2}Z"
	claims_json=$(_pmpc_gh_read api "$(_pm_issue_api "$repo_slug" "$issue_num")/comments?per_page=100" \
		--paginate --slurp 2>/dev/null) || return 1
	printf '%s' "$claims_json" | jq -e --arg author "$author" --arg issue "$issue_num" \
		--arg branch "$branch_iso" --argjson window "$_PMPC_CLAIM_BRANCH_WINDOW_S" "${_PMPC_COMMENTS_JQ_DEFS}"'
		($branch | fromdateiso8601) as $branch_epoch
		| any(comments[] | select((.user.login // "") == $author)
			| (.body // "") | split("\n")[] | sub("\r$"; "")
			| select(test("^DISPATCH_CLAIM nonce=[^ ]+ "))
			| select(test(" runner=" + $author + "( |$)"))
			| select(test(" session=issue-" + $issue + "( |$)"))
			| (capture(" ts=(?<ts>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)( |$)").ts
				| fromdateiso8601 - $branch_epoch);
			(if . < 0 then -. else . end) <= $window)
	' >/dev/null 2>&1
	return $?
}

#######################################
# Prove worker provenance for a PR that lacks an origin:* label.
# Requires a worker branch name, an author with current write access, and
# either the aidevops worker body marker (GH#37204) or a claim matching the
# branch (GH#38042). Never infer trust from the marker or branch name alone.
# Args: $1=repo slug, $2=head ref, $3=author login, $4=PR body
# Returns: 0 when proven, 1 otherwise
#######################################
_pmpc_worker_branch_provenance() {
	local pr_body="$4"
	local repo_slug="$1" head_ref="$2" author="$3" permission=""
	[[ "$head_ref" =~ ^feature/auto-[0-9]{8}-[0-9]{6}-gh[0-9]+$ ]] || return 1
	[[ "$author" =~ ^[A-Za-z0-9-]+$ ]] || return 1
	# aidevops:trust-boundary: require current repository write access.
	permission=$(_pmpc_gh_read api "repos/${repo_slug}/collaborators/${author}/permission" --jq '.permission' 2>/dev/null) || return 1
	case "$permission" in admin | maintain | write) ;; *) return 1 ;; esac
	[[ "$pr_body" == *"<!-- aidevops:origin:worker -->"* ]] && return 0
	_pmpc_branch_claim_matches "$repo_slug" "$head_ref" "$author"
	return $?
}

# GH#37204/GH#38042: merged worker partial PRs created without an origin label
# stranded their target in status:in-review. Accept a missing label only for a
# merged PR with independently verified worker provenance.
_pmpc_unlabeled_worker_provenance() {
	local pr_body
	local repo_slug="$1" pr_number="$2" pr_json="" fields="" author="" head_ref=""
	pr_json=$(_pmpc_gh_read api "repos/${repo_slug}/pulls/${pr_number}" 2>/dev/null) || return 1
	fields=$(printf '%s' "$pr_json" | jq -er '
		select(.merged == true and (.head.ref | type == "string")
			and (.user.login | type == "string")) | [.user.login, .head.ref] | @tsv
	' 2>/dev/null) || return 1
	IFS=$'\t' read -r author head_ref <<<"$fields"
	pr_body=$(printf '%s' "$pr_json" | jq -r '.body // ""' 2>/dev/null) || return 1
	_pmpc_worker_branch_provenance "$repo_slug" "$head_ref" "$author" "$pr_body"
	return $?
}

#######################################
# GH#38042: never merge a worker-branch PR whose origin is unproven. A
# feature/auto-* PR without any origin:* label is reconciled to origin:worker
# only on marker or claim-matched provenance, then re-evaluated next pass under
# the worker gates. Unprovable provenance blocks the merge.
# Args: $1=PR number, $2=repo slug, $3=PR author, $4=labels CSV,
#       $5=PR JSON (headRefName, body)
# Returns: 0 to continue gating, 1 to skip this merge
#######################################
_pm_gate_unlabeled_worker_branch() {
	local pr_number="$1" repo_slug="$2" pr_author="$3" labels_str="$4" info_json="$5"
	local head_ref="" pr_body=""
	[[ ",${labels_str}," != *",origin:"* ]] || return 0
	head_ref=$(printf '%s' "$info_json" | jq -r '.headRefName // ""' 2>/dev/null) || head_ref=""
	[[ "$head_ref" == feature/auto-* ]] || return 0
	pr_body=$(printf '%s' "$info_json" | jq -r '.body // ""' 2>/dev/null) || pr_body=""
	# #aidevops:trust-boundary — fail closed when worker origin cannot be proven.
	if ! _pmpc_worker_branch_provenance "$repo_slug" "$head_ref" "$pr_author" "$pr_body"; then
		echo "[pulse-wrapper] Merge pass: skipping PR #${pr_number} in ${repo_slug} — worker branch ${head_ref} has no origin label and no provable worker provenance (GH#38042)" >>"$LOGFILE"
		return 1
	fi
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		echo "[pulse-wrapper] Merge pass: PR #${pr_number} in ${repo_slug} — would restore origin:worker from verified provenance (GH#38042)" >>"$LOGFILE"
	elif declare -F set_origin_label >/dev/null 2>&1 &&
		set_origin_label "$pr_number" "$repo_slug" worker --pr >/dev/null 2>&1; then
		echo "[pulse-wrapper] Merge pass: PR #${pr_number} in ${repo_slug} — restored origin:worker from verified provenance; re-evaluating under worker gates next pass (GH#38042)" >>"$LOGFILE"
	else
		echo "[pulse-wrapper] Merge pass: skipping PR #${pr_number} in ${repo_slug} — origin:worker reconciliation failed (GH#38042)" >>"$LOGFILE"
	fi
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
# The newest trusted coordination event must be a claim release, terminal lease
# or lease expired beyond PULSE_PARTIAL_LEASE_GRACE_SECONDS (default 900).
# Any later claim means another owner is live. A marker means work was done.
# Args: $1=comments JSON (one page or `gh api --paginate --slurp` pages),
#       $2=merged PR number
# Stdout: runner login (runner= field of CLAIM_RELEASED, else comment author)
# Returns: 0 when a finished worker run is the newest owner, 1 otherwise
#          (including any unreadable comment entry)
#######################################
_pmpc_release_owner_from_comments() {
	local comments_json="$1"
	local pr_number="$2"
	local verdict="" now_epoch="" grace="${PULSE_PARTIAL_LEASE_GRACE_SECONDS:-900}"
	[[ "$grace" =~ ^[0-9]+$ ]] || grace=900
	now_epoch=$(date +%s) || return 1
	verdict=$(printf '%s' "$comments_json" | jq -r \
		--argjson now "$now_epoch" --argjson grace "$grace" \
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
			elif (.body | test("(^|\n)DISPATCH_LEASE phase=")) then
				. as $event
				| [(.body | split("\n")[] | select(test("^DISPATCH_LEASE phase="))
					| capture("(^| )expires_at=(?<expiry>[0-9]+)([ \\r]|$)") | .expiry | tonumber)] as $expiries
				| if ($expiries | length) == 1 and $expiries[0] < ($now - $grace)
					then "released:" + $event.login else "live" end
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
# Args: $1=PR number, $2=repo slug, $3=optional PR body (skips live read)
# Returns: 0 when a closing reference exists or unreadable, 1 when absent.
# Sets _PMPC_BODY_STATUS to distinguish unreadable from a real closing reference.
#######################################
_pmpc_pr_body_has_closing_ref() {
	local pr_number="$1"
	local repo_slug="$2"
	local supplied_body="${3-}"
	local pr_body="" verdict=""
	_PMPC_BODY_STATUS=unreadable
	if [[ "$#" -ge 3 ]]; then
		pr_body="$supplied_body"
	else
		pr_body=$(gh_pr_view "$pr_number" --repo "$repo_slug" --json body --jq '.body // ""' 2>/dev/null) || return 0
	fi
	verdict=$(printf '%s' "$pr_body" | jq -Rrs --arg pattern "$_PMPC_CLOSING_REF_PATTERN" \
		'test($pattern; "i")' 2>/dev/null) || return 0
	_PMPC_BODY_STATUS=readable
	[[ "$verdict" == "false" ]] && return 1
	return 0
}

#######################################
# Resolve a title target corroborated by a visible For/Ref body reference.
# Unlike the shared explicit resolver, secondary sections and mid-line refs
# are eligible here: the title independently identifies the partial's target.
# Args: $1=PR number, $2=repo slug, $3=optional PR body (title stays live)
# Stdout: corroborated issue number
# Returns: 0 when corroborated, 1 when absent or unreadable
#######################################
_pmpc_corroborated_target() {
	local pr_number="$1"
	local repo_slug="$2"
	local supplied_body="${3-}"
	local pr_title="" pr_body="" title_target="" target=""
	pr_title=$(gh_pr_view "$pr_number" --repo "$repo_slug" --json title --jq '.title // empty' 2>/dev/null) || return 1
	[[ "$pr_title" =~ ^(t|GH#)([0-9]+)([^[:alnum:]_]|$) ]] || return 1
	title_target="${BASH_REMATCH[2]}"
	if [[ "$#" -ge 3 ]]; then
		pr_body="$supplied_body"
	else
		pr_body=$(gh_pr_view "$pr_number" --repo "$repo_slug" --json body --jq '.body // empty' 2>/dev/null) || return 1
	fi
	target=$(printf '%s\n' "$pr_body" | awk -v target="$title_target" '
		{
			line = $0
			# Quoted fences must not open or close an unquoted code block.
			if (!comment && line ~ /^[[:space:]]*>/) next
			if (!fence) {
				visible = ""
				while (length(line)) {
					if (comment) {
						if (!match(line, /-->/)) { line = ""; break }
						line = substr(line, RSTART + RLENGTH)
						comment = 0
					} else if (match(line, /<!--/)) {
						visible = visible substr(line, 1, RSTART - 1) " "
						line = substr(line, RSTART + RLENGTH)
						comment = 1
					} else { visible = visible line; break }
				}
				line = visible
			}
			# Markdown fences allow at most three leading spaces, not tabs.
			if (line ~ /^ ? ? ?(```|~~~)/) {
				sub(/^[[:space:]]*/, "", line)
				match(line, /^(`+|~+)/)
				run = substr(line, 1, RLENGTH)
				if (!fence) {
					fence = 1; marker = substr(run, 1, 1); size = length(run)
				} else if (substr(run, 1, 1) == marker && length(run) >= size &&
					substr(line, length(run) + 1) ~ /^[[:space:]]*$/) fence = 0
				next
			}
			if (fence || line ~ /^[[:space:]]*>/ || line ~ /^(    |\t)/) next
			if (tolower(line) ~ ("(^|[^[:alnum:]_])(for|ref)[:[:space:]]+#" target "([^[:alnum:]_]|$)")) found = 1
		}
		END { if (found) print target }
	') || return 1
	[[ "$target" =~ ^[0-9]+$ ]] || return 1
	printf '%s' "$target"
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
# that closes no issue in any GitHub reference form and whose explicit or
# title-corroborated For/Ref issue is open, status:in-review, unprotected, owned only by the
# finished worker run, and not referenced by another open PR. Leaves regain
# auto-dispatch; parent-task trackers end without it.
#
# Args: $1=merged PR number, $2=repo slug, $3=closing target (empty for
#       non-closing partials), $4=PR labels CSV (fetched when empty),
#       $5=expected issue target for periodic reconciliation (optional)
# Returns: 0 always (best-effort post-merge hygiene)
#######################################
_pm_restore_partial_continuation() {
	local pr_number="$1"
	local repo_slug="$2"
	local linked_issue="${3:-}"
	local pr_labels="${4:-}"
	local expected_target="${5:-}"
	local closing="" target="" issue_api="" issue_json="" scope="" comments_json=""
	local runner_login="" pr_author="" assignees="" parent_has_dispatch=0 body_rc=0

	[[ -z "$linked_issue" && "$pr_number" =~ ^[0-9]+$ && "$repo_slug" == */* ]] || return 0
	if [[ -z "$pr_labels" ]]; then
		pr_labels=$(gh_pr_view "$pr_number" --repo "$repo_slug" --json labels \
			--jq '[.labels[].name] | join(",")' 2>/dev/null) || return 0
	fi
	if [[ ",${pr_labels}," != *",origin:worker,"* && ",${pr_labels}," != *",origin:worker-takeover,"* ]]; then
		# Conflicting origins are not missing provenance and must not be overridden.
		[[ ",$pr_labels," != *",origin:"* ]] || return 0
		_pmpc_unlabeled_worker_provenance "$repo_slug" "$pr_number" || return 0
		echo "[pulse-wrapper] Deterministic merge: PR #${pr_number} has no origin label; accepted verified worker provenance (branch, body marker, write-access author) for partial continuation (GH#37204)" >>"$LOGFILE"
	fi
	# An empty caller target can also mean the upstream closing-target read
	# failed, and the explicit resolver returns a closing target first. Prove
	# independently that the PR closes nothing before using its For/Ref target.
	closing=$(_extract_linked_issue "$pr_number" "$repo_slug" 2>/dev/null) || return 0
	if [[ -n "$closing" ]]; then
		echo "[pulse-wrapper] Deterministic merge: no partial continuation for PR #${pr_number} — it closes #${closing} (GH#38869)" >>"$LOGFILE"
		return 0
	fi
	_pmpc_pr_body_has_closing_ref "$pr_number" "$repo_slug" || body_rc=$?
	if [[ "$body_rc" -ne 1 ]]; then
		if [[ "$_PMPC_BODY_STATUS" == unreadable ]]; then
			echo "[pulse-wrapper] Deterministic merge: no partial continuation for PR #${pr_number} — body unreadable (GH#38885)" >>"$LOGFILE"
		else
			echo "[pulse-wrapper] Deterministic merge: no partial continuation for PR #${pr_number} — body closes an issue (GH#34312)" >>"$LOGFILE"
		fi
		return 0
	fi
	target=$(_extract_pr_work_issue "$pr_number" "$repo_slug" explicit 2>/dev/null) || target=""
	if [[ ! "$target" =~ ^[0-9]+$ || ( -n "$expected_target" && "$target" != "$expected_target" ) ]]; then
		target=$(_pmpc_corroborated_target "$pr_number" "$repo_slug") || return 0
	fi
	[[ "$target" =~ ^[0-9]+$ ]] || return 0
	[[ -z "$expected_target" || "$target" == "$expected_target" ]] || return 0
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

# GH#37043: restore stranded available worker issues, including late draft
# releases after a partial merged. An open PR (draft or ready), uncertain reads,
# active ownership or any independent recovery hold must prevent this repair.
# $3 is set only by the runtime immediately after its own persisted release;
# issue authorship need not be worker-origin for that owned release.
_pmpc_restore_available_dispatch() {
	local repo_slug="$1" issue_num="$2" released_worker="${3:-0}"
	local issue_json="" history_json="" safe="" current_epoch="" body=""
	issue_json=$(_pmpc_gh_read api "repos/${repo_slug}/issues/${issue_num}" 2>/dev/null) || return 1
	printf '%s' "$issue_json" | jq -e --arg released "$released_worker" --arg array array --arg dispatch auto-dispatch '
		[.labels[].name] as $labels
		| .state == "open" and .pull_request == null
		and (.assignees | type == $array and length == 0)
		and ([$labels[] | select(startswith("status:"))] == ["status:available"])
		and ($released == "1" or ($labels | index("origin:worker")) != null)
		and ($labels | all(. != $dispatch and . != "no-auto-dispatch"
			and . != "parent-task" and . != "hold-for-review" and . != "lockdown"
			and . != "needs-maintainer-review" and . != "needs-maintainer-permissions"
			and . != "persistent"))
	' >/dev/null 2>&1 || return 1
	history_json=$(_pmpc_gh_read api "repos/${repo_slug}/issues/${issue_num}/comments?per_page=100" \
		--paginate --slurp 2>/dev/null) || return 1
	current_epoch=$(date +%s) || return 1
	# Escalated tasks use release-stale-recovery, which verifies live maintainer
	# permission and restores the label itself. Do not infer that authority from
	# comment association or a copied release marker in this automatic repair.
	safe=$(printf '%s' "$history_json" | jq -r --argjson now "$current_epoch" \
		--arg pattern "$_PMPC_EVENT_PATTERN" "${_PMPC_COMMENTS_JQ_DEFS}"'
		[comments[] | select(trusted)] | sort_by(.created_at, .id) as $trusted
		| [$trusted[] | select((.body // "") | test($pattern))] | last as $owner
		| if any($trusted[]; (.body // "") | test("cost-circuit-breaker:fired|worker-recovery-loop:blocked|dispatch-circuit-breaker:worker_recovery_loop|stale-recovery-tick:escalated")) then false
		elif $owner == null then true
		elif ($owner.body | test("(?m)^CLAIM_RELEASED reason=worker_ownership_lost")) then false
		elif ($owner.body | test("(?m)^CLAIM_RELEASED reason=blocked")) then false
		elif ($owner.body | test("(?m)^CLAIM_RELEASED reason=|^DISPATCH_LEASE phase=terminal ")) then true
		elif ($owner.body | test("(?m)^DISPATCH_LEASE phase=")) then
			[($owner.body | split("\n")[] | select(startswith("DISPATCH_LEASE phase="))
				| capture("(^| )expires_at=(?<expiry>[0-9]+)([ \\r]|$)") | .expiry | tonumber)] as $expiries
			| ($expiries | length) == 1 and $expiries[0] < ($now - 900)
		else false end
	' 2>/dev/null) || return 1
	[[ "$safe" == true ]] || return 1
	_pmpc_other_open_pr_owns_issue "$repo_slug" "$issue_num" 0 && return 1
	set_issue_status "$issue_num" "$repo_slug" available --add-label auto-dispatch >/dev/null 2>&1 || return 1
	body="<!-- ops:start -->
<!-- aidevops:ops kind=available-dispatch-recovery -->
Restored auto-dispatch on this unassigned available worker issue after verifying no open linked PR, live owner or recovery circuit hold. Existing dispatch, approval and dependency guards remain in force.
<!-- ops:end -->"
	gh_issue_comment "$issue_num" --repo "$repo_slug" --body "$body" >/dev/null 2>&1 || {
		printf '[pulse-wrapper] Available dispatch recovery: #%s restored but audit write failed\n' "$issue_num" >>"$LOGFILE"
		return 1
	}
	return 0
}

# GH#38355: a worker draft checkpoint removes auto-dispatch only so that no
# second branch opens beside the open draft. When that draft is closed without
# merging, nothing continues it (dispatch-stalled acts on open drafts only) and
# the issue stayed undispatchable for any origin. Any closer counts: workers
# often share the maintainer's login, and the removal's only reason is gone.
_PMPC_CLOSED_CHECKPOINT_KIND="closed-checkpoint-dispatch-recovery"

# Classify the issue for the closed-checkpoint restore.
# Args: $1=issue JSON (REST)
# Stdout: "unassigned" (status:available) or "review <login>" (status:in-review,
#         one assignee); nothing when closed, held, already dispatchable or other
_pmpc_closed_checkpoint_issue_mode() {
	local issue_json="$1"
	printf '%s' "$issue_json" | jq -r '
		[.labels[].name] as $labels
		| ([$labels[] | select(test("^status:"))] | join(",")) as $status
		| if (.state != "open" or .pull_request != null
			or ($labels | any(test("^((no-)?auto-dispatch|parent-task|hold-for-review|lockdown|persistent|needs-.*)$")))) then empty
		elif (($status | test("^status:available$")) and .assignees == []) then "unassigned"
		elif (($status | test("^status:in-review$")) and (.assignees | length) == 1) then "review " + .assignees[0].login
		else empty end
	' 2>/dev/null || return 1
	return 0
}

# The newest trusted ownership event must be this checkpoint's release, with no
# recovery-circuit hold and no restore already recorded for the PR.
# Args: $1=comments JSON (pages), $2=PR number
# Stdout: "<release epoch> <runner login>"; nothing when ineligible
_pmpc_closed_checkpoint_release() {
	local comments_json="$1" pr_number="$2"
	printf '%s' "$comments_json" | jq -r --arg pattern "$_PMPC_EVENT_PATTERN" \
		--arg marker "kind=${_PMPC_CLOSED_CHECKPOINT_KIND} pr=${pr_number} " "${_PMPC_COMMENTS_JQ_DEFS}"'
		[comments[] | select(trusted) | .body //= ""] | sort_by(.created_at, .id) as $trusted
		| ([$trusted[] | select(.body | test($pattern))] | last) as $owner
		| if any($trusted[]; .body | contains($marker)) then empty
		elif any($trusted[]; .body | test("cost-circuit-breaker:fired|worker-recovery-loop:blocked|dispatch-circuit-breaker:worker_recovery_loop|stale-recovery-tick:escalated")) then empty
		elif $owner == null then empty
		else $owner.body | capture("(?m)^CLAIM_RELEASED reason=worker_draft_checkpoint runner=(?<runner>[^ \\r\\n]+)")
			| "\($owner.created_at | fromdateiso8601) \(.runner)" end
	' 2>/dev/null || return 1
	return 0
}

# Prove the PR is this issue's checkpoint draft and was closed unmerged after
# the release: same-repo worker branch for the issue, opened before the release.
# Args: $1=repo slug, $2=PR number, $3=issue number, $4=release epoch
# Returns: 0 when proven, 1 when ineligible, 2 when unreadable (transient)
_pmpc_closed_checkpoint_pr_void() {
	local repo_slug="$1" pr_number="$2" issue_num="$3" release_epoch="$4" pr_json=""
	pr_json=$(_pmpc_gh_read api "repos/${repo_slug}/pulls/${pr_number:?}" 2>/dev/null) || return 2
	printf '%s' "$pr_json" | jq -e --arg slug "$repo_slug" --arg issue "$issue_num" \
		--argjson release "$release_epoch" '
		.state == "closed" and .merged == false and .merged_at == null
		and .head.repo.full_name == $slug
		and (.head.ref | type) == "string"
		and (.head.ref | test("(^|[/_-])gh-?" + $issue + "$"))
		and ((.created_at | fromdateiso8601) <= $release)
		and ((.closed_at | fromdateiso8601) >= $release)
	' >/dev/null 2>&1 || return 1
	return 0
}

# GH#37600: re-add only the label that the checkpoint removed. The newest
# auto-dispatch label event must be a removal in the checkpoint's own window:
# the escalation removes it moments before posting the release, so a removal
# more than an hour earlier was a person's (during the run) and is respected,
# as is a removal after the release or an issue that never had the label.
# Args: $1=repo slug, $2=issue number, $3=release epoch
# Returns: 0 when the checkpoint made the last removal, 1 otherwise, 2 when unreadable
_pmpc_checkpoint_removed_dispatch() {
	local repo_slug="$1" issue_num="$2" release_epoch="$3" events_json=""
	events_json=$(_pmpc_gh_read api "repos/${repo_slug}/issues/${issue_num}/events?per_page=100" \
		--paginate --slurp 2>/dev/null) || return 2
	printf '%s' "$events_json" | jq -e --argjson release "$release_epoch" '
		if type != "array" then error("unreadable events")
		elif (.[0]? | type) == "array" then [.[][]] else . end
		| [.[] | select((.event == "labeled" or .event == "unlabeled") and .label.name? == "auto-dispatch")]
		| last
		| . != null and .event == "unlabeled"
			and ((.created_at | fromdateiso8601) as $removed | $removed <= $release and $removed >= $release - 3600)
	' >/dev/null 2>&1 || return 1
	return 0
}

#aidevops:trust-boundary -- trusted release comments, the live PR and the label
# timeline prove the restore; any unreadable or held state means no write.
# Args: $1=repo slug, $2=issue number, $3=closed checkpoint PR number
# Returns: 0 when auto-dispatch was restored, 1 when ineligible, 2 on a transient
#          read or write failure (the checkpoint stays eligible for a later scan)
_pmpc_restore_closed_checkpoint_dispatch() {
	local repo_slug="$1" issue_num="$2" pr_number="$3"
	local issue_json="" mode="" assignee=""
	local comments_json="" release="" release_epoch="" runner="" body=""
	local -a transition_args=(--add-label auto-dispatch)
	[[ "$repo_slug" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ && "$issue_num" =~ ^[1-9][0-9]*$ &&
		"$pr_number" =~ ^[1-9][0-9]*$ ]] || return 1
	issue_json=$(_pmpc_gh_read api "repos/${repo_slug}/issues/${issue_num:?}" 2>/dev/null) || return 2
	mode=$(_pmpc_closed_checkpoint_issue_mode "$issue_json") || return 2
	[[ -n "$mode" ]] || return 1
	comments_json=$(_pmpc_gh_read api "repos/${repo_slug}/issues/${issue_num}/comments?per_page=100" \
		--paginate --slurp 2>/dev/null) || return 2
	release=$(_pmpc_closed_checkpoint_release "$comments_json" "$pr_number") || return 2
	read -r release_epoch runner <<<"$release"
	[[ "$release_epoch" =~ ^[0-9]+$ && "$runner" =~ ^[A-Za-z0-9._-]+(\[bot\])?$ ]] || return 1
	if [[ "$mode" == review\ * ]]; then
		# A runner left assigned in review is released only when it is the checkpoint's runner.
		assignee="${mode#review }"
		[[ "$assignee" == "$runner" ]] || return 1
		transition_args+=(--remove-assignee "$runner")
	fi
	local void_rc=0
	_pmpc_closed_checkpoint_pr_void "$repo_slug" "$pr_number" "$issue_num" "$release_epoch" || void_rc=$?
	[[ "$void_rc" -eq 0 ]] || return "$void_rc"
	_pmpc_checkpoint_removed_dispatch "$repo_slug" "$issue_num" "$release_epoch" || void_rc=$?
	[[ "$void_rc" -eq 0 ]] || return "$void_rc"
	_pmpc_other_open_pr_owns_issue "$repo_slug" "$issue_num" 0 && return 1
	set_issue_status "$issue_num" "$repo_slug" available "${transition_args[@]}" >/dev/null 2>&1 || return 2
	body="<!-- ops:start -->
<!-- aidevops:ops kind=${_PMPC_CLOSED_CHECKPOINT_KIND} pr=${pr_number} -->
Draft checkpoint PR #${pr_number} was closed without merging, so it no longer holds this issue. Restored the auto-dispatch label that the checkpoint removed, after verifying no open linked PR, hold or newer owner. The next worker starts from the default branch; it does not resume the closed PR's head.
<!-- ops:end -->"
	gh_issue_comment "$issue_num" --repo "$repo_slug" --body "$body" >/dev/null 2>&1 || {
		printf '[pulse-wrapper] Closed checkpoint recovery: #%s restored after PR #%s but audit write failed\n' "$issue_num" "$pr_number" >>"$LOGFILE"
		return 0
	}
	printf '[pulse-wrapper] Closed checkpoint recovery: #%s regained auto-dispatch after draft PR #%s closed unmerged (GH#38355)\n' "$issue_num" "$pr_number" >>"$LOGFILE"
	return 0
}

# Parse one page of the closed-PR listing (GH#38396).
# Output: first line "<page length> <oldest updated_at epoch>"; then one
# "<pr> <issue>" row per unmerged worker-branch PR closed at or after the floor.
# Args: $1=repo slug, $2=floor epoch, $3=page JSON
# Returns: 0 on success, 1 on an unreadable page
_pmpc_closed_checkpoint_rows() {
	local repo_slug="$1" floor="$2" page_json="$3"
	printf '%s' "$page_json" | jq -r --arg slug "$repo_slug" --argjson floor "$floor" '
		if type != "array" then error("unreadable PR list") else . end
		| "\(length) \(map(.updated_at // .closed_at // "" | if type == "string" and . != "" then fromdateiso8601 else 0 end) | min // 0)",
		(.[]
		| select(.merged_at == null and (.closed_at | type) == "string" and (.number | type) == "number")
		| select(.head.repo.full_name? == $slug)
		| select((.closed_at | fromdateiso8601) >= $floor)
		| (.head.ref // "" | capture("^feature/auto-[0-9]{8}-[0-9]{6}-gh(?<issue>[0-9]+)$").issue) as $issue
		| "\(.number) \($issue)")
	' 2>/dev/null || return 1
	return 0
}

# Scan every unmerged worker-branch PR closed since the previous complete scan
# (within the lookback) once per partial-continuation traversal and offer each
# linked issue to the restore above (GH#38396). Pages are read newest-updated
# first and the scan stops when a page's oldest updated_at is below the floor
# (updated_at >= closed_at), the page is short, the deadline passes, or the page
# cap is reached. The stamp (start epoch) advances only after the floor was
# reached, so a deadline, page-cap or unreadable-page stop rescans the gap.
# Args: $1=repo slug, $2=deadline epoch, $3=traversal cursor "<phase>:<page>:<pending>";
#       only a fresh traversal ("review:1:") scans, so resumed pages do not repeat it
# Returns: 0 when scanned or not due, 1 on an unreadable listing
_pmpc_reconcile_closed_checkpoints() {
	local repo_slug="$1" deadline="$2" traversal="${3:-review:1:}" page_json="" rows="" pr="" issue=""
	local now_epoch="" start_epoch="" floor="" stamp="" stamp_file="" first="" oldest=""
	local count=""
	local page=1 reached=0 transient=0 restore_rc=0
	[[ "$traversal" == "review:1:" ]] || return 0
	local lookback="${PULSE_CLOSED_CHECKPOINT_LOOKBACK_SECONDS:-604800}"
	[[ "$lookback" =~ ^[1-9][0-9]{0,8}$ ]] || lookback=604800
	local per_page="${PULSE_CLOSED_CHECKPOINT_PAGE_SIZE:-100}"
	[[ "$per_page" =~ ^[1-9][0-9]*$ && "$per_page" -le 100 ]] || per_page=100
	local max_pages="${PULSE_CLOSED_CHECKPOINT_MAX_PAGES:-10}"
	[[ "$max_pages" =~ ^[1-9][0-9]{0,2}$ ]] || max_pages=10
	local stamp_dir="${PULSE_PARTIAL_RECONCILE_STATE_DIR:-${HOME}/.aidevops/cache/partial-continuation}"
	stamp_file="${stamp_dir}/${repo_slug//\//__}.closed-scan"
	start_epoch=$(date +%s) || return 1
	floor=$((start_epoch - lookback))
	if [[ -r "$stamp_file" ]]; then
		read -r stamp <"$stamp_file" || stamp=""
		# A stamp can only narrow the window to the last complete scan minus a margin.
		if [[ "$stamp" =~ ^[0-9]{1,10}$ && $((stamp - 3600)) -gt "$floor" ]]; then
			floor=$((stamp - 3600))
		fi
	fi
	while [[ "$page" -le "$max_pages" ]]; do
		now_epoch=$(date +%s) || return 1
		[[ "$now_epoch" -lt "$deadline" ]] || return 0
		page_json=$(_pmpc_gh_read api "repos/${repo_slug}/pulls?state=closed&sort=updated&direction=desc&per_page=${per_page}&page=${page}" 2>/dev/null) || return 1
		rows=$(_pmpc_closed_checkpoint_rows "$repo_slug" "$floor" "$page_json") || return 1
		first="${rows%%$'\n'*}"
		read -r count oldest <<<"$first"
		[[ "$count" =~ ^[0-9]+$ && "$oldest" =~ ^[0-9]+$ ]] || return 1
		[[ "$rows" == *$'\n'* ]] && rows="${rows#*$'\n'}" || rows=""
		while read -r pr issue; do
			[[ "$pr" =~ ^[0-9]+$ && "$issue" =~ ^[0-9]+$ ]] || continue
			now_epoch=$(date +%s) || return 1
			[[ "$now_epoch" -lt "$deadline" ]] || return 0
			restore_rc=0
			_pmpc_restore_closed_checkpoint_dispatch "$repo_slug" "$issue" "$pr" || restore_rc=$?
			# A transient failure keeps the stamp unchanged so the gap is rescanned.
			[[ "$restore_rc" -ne 2 ]] || transient=1
		done <<<"$rows"
		if [[ "$count" -lt "$per_page" || "$oldest" -lt "$floor" ]]; then
			reached=1
			break
		fi
		page=$((page + 1))
	done
	if [[ "$reached" -eq 1 && "$transient" -eq 0 ]]; then
		mkdir -p "$stamp_dir" 2>/dev/null || return 0
		printf '%s\n' "$start_epoch" >"${stamp_file}.$$" 2>/dev/null &&
			mv -f "${stamp_file}.$$" "$stamp_file" 2>/dev/null || rm -f "${stamp_file}.$$" 2>/dev/null
	fi
	return 0
}

# Revisit recent merged PRs independently of the issue traversal cursor. Repeat
# the lookback window rather than stamping a scan complete: restore is best
# effort and an unreadable issue or PR must be retried on a later cycle.
_pmpc_reconcile_recent_merges() {
	local repo_slug="$1" deadline="$2" now_epoch="" page_json="" rows="" pr=""
	local state_dir="${PULSE_PARTIAL_RECONCILE_STATE_DIR:-${HOME}/.aidevops/cache/partial-continuation}"
	local cursor="${state_dir}/${repo_slug//\//__}.merged-page" page=1 count=0 oldest=0 floor=0 line="" loaded=0
	local lookback="${PULSE_PARTIAL_MERGED_LOOKBACK_SECONDS:-604800}"
	[[ "$lookback" =~ ^[1-9][0-9]{0,8}$ ]] || lookback=604800
	if [[ -r "$cursor" ]]; then
		while IFS= read -r line; do
			if [[ "$loaded" -eq 0 ]]; then page="$line"; loaded=1
			elif [[ "$line" =~ ^[0-9]+$ ]]; then rows="${rows}${rows:+$'\n'}${line}"; fi
		done <"$cursor"
	fi
	[[ "$page" =~ ^[1-9][0-9]{0,3}$ ]] || page=1
	now_epoch=$(date +%s) || return 1
	[[ "$now_epoch" -lt "$deadline" ]] || return 3
	if [[ -z "$rows" ]]; then
		floor=$((now_epoch - lookback))
		page_json=$(_pmpc_gh_read api "repos/${repo_slug}/pulls?state=closed&sort=updated&direction=desc&per_page=100&page=${page}" 2>/dev/null) || return 1
		rows=$(printf '%s' "$page_json" | jq -r --argjson floor "$floor" '
		if type != "array" then error("unreadable PR list") else . end
		| "\(length) \(map(.updated_at // "" | if type == "string" and . != "" then fromdateiso8601 else 0 end) | min // 0)",
		  (.[] | select((.number | type) == "number" and (.merged_at | type) == "string")
		   | select((.merged_at | fromdateiso8601) >= $floor) | .number)
		' 2>/dev/null) || return 1
		read -r count oldest <<<"${rows%%$'\n'*}"
		[[ "$count" =~ ^[0-9]+$ && "$oldest" =~ ^[0-9]+$ ]] || return 1
		[[ "$rows" == *$'\n'* ]] && rows="${rows#*$'\n'}" || rows=""
		if [[ "$count" -lt 100 || "$oldest" -lt "$floor" ]]; then page=1; else page=$((page + 1)); fi
	fi
	mkdir -p "$state_dir" 2>/dev/null || return 1
	while [[ -n "$rows" ]]; do
		# Persist the unprocessed suffix before each attempt, so a deadline or
		# interrupted process cannot repeatedly starve the end of a full page.
		printf '%s\n%s\n' "$page" "$rows" >"${cursor}.$$" && mv -f "${cursor}.$$" "$cursor" || return 1
		now_epoch=$(date +%s) || return 1
		[[ "$now_epoch" -lt "$deadline" ]] || return 3
		pr="${rows%%$'\n'*}"
		_pm_restore_partial_continuation "$pr" "$repo_slug" "" ""
		[[ "$rows" == *$'\n'* ]] && rows="${rows#*$'\n'}" || rows=""
	done
	printf '%s\n' "$page" >"${cursor}.$$" && mv -f "${cursor}.$$" "$cursor" || return 1
	[[ "$page" -eq 1 ]] || return 3
	return 0
}

# GH#38021: a worker draft checkpoint removes auto-dispatch so that no second
# branch opens beside the draft. A canonical consolidated spec is a dispatch
# candidate only while it carries that label (_has_consolidated_label), and the
# restore above refuses while a PR is open, so the exact-head continuation
# never started until a person re-added the label.
# The pair below restores only the removal made by the same worker run. The
# receipt comes from that run's read taken before the escalation, so a label a
# person removed earlier is never re-added (GH#37600).
# Keep the marker pattern in step with _has_consolidated_label.
_PMPC_SPEC_MARKER_PATTERN='(^|\n)_Supersedes #[0-9]+ (—|-) this issue is the consolidated spec\._(\n|$)'
_PMPC_SPEC_HOLD_LABELS='no-auto-dispatch parent-task hold-for-review lockdown persistent'
_PMPC_CHECKPOINT_SPEC_RECEIPT=""

# Classify one issue for the pair below from a single uncached read.
# Args: $1=repo slug, $2=issue number
# Stdout: "carries" when an open canonical spec has auto-dispatch; "restorable"
#         when it has neither the label, an assignee, a hold nor any status
#         other than status:available; nothing for every other issue.
# Returns: 0 when the issue was read, 1 when it could not be read
_pmpc_checkpoint_spec_state() {
	local repo_slug="$1" issue_num="$2" issue_json=""
	[[ "$repo_slug" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ && "$issue_num" =~ ^[1-9][0-9]*$ ]] || return 1
	issue_json=$(_pmpc_gh_read api "repos/${repo_slug}/issues/${issue_num}" 2>/dev/null) || return 1
	printf '%s' "$issue_json" | jq -r --arg pattern "$_PMPC_SPEC_MARKER_PATTERN" \
		--arg holds "$_PMPC_SPEC_HOLD_LABELS" --arg dispatch auto-dispatch \
		--arg open open --arg status status: --arg available status:available '
		[.labels[].name] as $labels
		| ($holds | split(" ")) as $hold_list
		| if (.state != $open or .pull_request != null
			or ($labels | index("consolidated")) == null
			or ((.body // "") | test($pattern) | not)) then empty
		elif ($labels | index($dispatch)) != null then "carries"
		elif (.assignees == []
			and [$labels[] | select(startswith($status))] == [$available]
			and ($labels - $hold_list) == $labels
			and ($labels | any(startswith("needs-")) | not)) then "restorable"
		else empty end
	' 2>/dev/null || return 1
	return 0
}

# Call before the checkpoint escalation removes the label.
# Args: $1=repo slug, $2=issue number
# Returns: 0 when the receipt names this issue, 1 otherwise (unreadable included)
_pmpc_record_checkpoint_spec_dispatch() {
	local repo_slug="$1" issue_num="$2" state=""
	local receipt_key="${repo_slug}#${issue_num}"
	# A repeated escalation in this run reads the label after the first removal;
	# the earlier proof still stands.
	[[ "$_PMPC_CHECKPOINT_SPEC_RECEIPT" != "$receipt_key" ]] || return 0
	_PMPC_CHECKPOINT_SPEC_RECEIPT=""
	state=$(_pmpc_checkpoint_spec_state "$repo_slug" "$issue_num") || return 1
	[[ "$state" == carries ]] || return 1
	_PMPC_CHECKPOINT_SPEC_RECEIPT="$receipt_key"
	return 0
}

# A release that cannot be published is replayed later by another process
# (headless-runtime-release-retry.sh). Its private row carries the receipt
# across: the recording run reports it with the first function and the replay
# adopts it with the second. Nothing else may adopt a receipt.
# Args: $1=repo slug, $2=issue number
# Returns: 0 when this process holds the receipt for the issue, 1 otherwise
_pmpc_holds_checkpoint_spec_receipt() {
	local repo_slug="$1" issue_num="$2"
	[[ -n "$_PMPC_CHECKPOINT_SPEC_RECEIPT" &&
		"$_PMPC_CHECKPOINT_SPEC_RECEIPT" == "${repo_slug}#${issue_num}" ]] || return 1
	return 0
}

# Args: $1=repo slug, $2=issue number
# Returns: 0 when the receipt was adopted, 1 for a malformed issue reference
_pmpc_adopt_checkpoint_spec_receipt() {
	local repo_slug="$1" issue_num="$2"
	[[ "$repo_slug" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ && "$issue_num" =~ ^[1-9][0-9]*$ ]] || return 1
	_PMPC_CHECKPOINT_SPEC_RECEIPT="${repo_slug}#${issue_num}"
	return 0
}

#aidevops:trust-boundary -- relabels only on the pre-removal receipt of the run
# that removed the label; timeline or comment text is never evidence. The
# receipt is consumed on use.
# Call after the release projection. Holds added during the run stay in force.
# Args: $1=repo slug, $2=issue number
# Returns: 0 when auto-dispatch was restored; 1 when there was nothing to
#          restore (no receipt, or the label is already back); 2 when the
#          receipt was held but the issue was unreadable, held, owned, not
#          available, or the write failed.
_pmpc_restore_checkpoint_spec_dispatch() {
	local repo_slug="$1" issue_num="$2" state=""
	_pmpc_holds_checkpoint_spec_receipt "$repo_slug" "$issue_num" || {
		_PMPC_CHECKPOINT_SPEC_RECEIPT=""
		return 1
	}
	_PMPC_CHECKPOINT_SPEC_RECEIPT=""
	state=$(_pmpc_checkpoint_spec_state "$repo_slug" "$issue_num") || return 2
	[[ "$state" != carries ]] || return 1
	[[ "$state" == restorable ]] || return 2
	set_issue_status "$issue_num" "$repo_slug" available --add-label auto-dispatch >/dev/null 2>&1 || return 2
	return 0
}

# GH#38039: list one page of label-filtered revisit candidates.
# Args: $1=repo slug, $2=phase (review|available), $3=page, $4=page size
# Stdout: the raw page length on line 1, then one candidate issue number per line
# Returns: 0 on success, 1 on an unreadable listing
_pmpc_list_candidates() {
	local repo_slug="$1" phase="$2" page="$3" cap="$4" labels="status:in-review" page_json="" numbers="" count=""
	[[ "$phase" != available ]] || labels="status:available,origin:worker"
	page_json=$(_pmpc_gh_read api "repos/${repo_slug}/issues?state=open&labels=${labels}&sort=created&direction=asc&per_page=${cap}&page=${page}" 2>/dev/null) || return 1
	numbers=$(printf '%s' "$page_json" | jq -r --arg phase "$phase" '
		if type != "array" or any(.[]; (.number | type) != "number") then error("unreadable issues")
		else .[] | select(.pull_request == null)
			| select($phase != "available" or ([(.labels // [])[] | (.name? // .)] | index("auto-dispatch") | not))
			| .number end
	' 2>/dev/null) || return 1
	count=$(printf '%s' "$page_json" | jq 'length') || return 1
	printf '%s\n' "$count"
	[[ -z "$numbers" ]] || printf '%s\n' "$numbers"
	return 0
}

# Revisit one in-review issue: walk its merged cross-referenced PRs newest
# first and let the merge-time guard decide. Timeline cross-references carry
# merged_at. A PR closing a different (sibling) issue is skipped so it cannot
# hide an older eligible partial; the first PR that closes this issue stops the
# walk with no restore, and the first non-closing PR goes to the guard.
# Args: $1=repo slug, $2=issue number
# Returns: 0 when handled or nothing to do, 1 on an unreadable timeline
_pmpc_revisit_in_review_issue() {
	local repo_slug="$1" issue_num="$2" timeline="" pr_numbers="" pr_number="" closing=""
	timeline=$(_pmpc_gh_read api "repos/${repo_slug}/issues/${issue_num}/timeline?per_page=100" --paginate --slurp 2>/dev/null) || return 1
	pr_numbers=$(printf '%s' "$timeline" | jq -r --arg repo "https://api.github.com/repos/${repo_slug}" '
		if type != "array" then error("unreadable timeline")
		elif (.[0]? | type) == "array" then [.[][]] else . end
		| [ .[] | select(.event == "cross-referenced") | .source.issue
			| select(.repository_url == $repo and (.pull_request.merged_at | type) == "string") ]
		| sort_by(.pull_request.merged_at, .number) | reverse | .[]
		| if (.number | type) == "number" then .number
			else error("unreadable PR number") end
	' 2>/dev/null) || return 1
	while IFS= read -r pr_number; do
		[[ "$pr_number" =~ ^[0-9]+$ ]] || continue
		closing=$(_extract_linked_issue "$pr_number" "$repo_slug" 2>/dev/null) || return 0
		if [[ -n "$closing" && "$closing" != "$issue_num" ]]; then
			echo "[pulse-wrapper] Deterministic merge: skipped merged PR #${pr_number} in #${issue_num} revisit — it closes sibling issue #${closing} (GH#38869)" >>"$LOGFILE"
			continue
		fi
		# The merge-time guard re-reads all current issue/PR/comment metadata
		# and returns without a restore when this PR closes the issue.
		_pm_restore_partial_continuation "$pr_number" "$repo_slug" "" "" "$issue_num"
		return 0
	done <<<"$pr_numbers"
	return 0
}

# GH#34432: revisit one bounded page of candidate issues on the existing
# per-repo stale-blocked cadence. GH#38039: only label-filtered candidates are
# listed (status:in-review for the restore path, then status:available
# origin:worker issues without auto-dispatch for _pmpc_restore_available_dispatch),
# never every open issue. Persist the next page, pending issue IDs and their
# phase before processing so a killed/slow issue cannot starve the page suffix.
# Full pages continue within the deadline (GH#38677; optional page budget
# PULSE_PARTIAL_RECONCILE_MAX_PAGES, 0 = unbounded); the final available page
# resets the cursor and starts the normal cadence interval.
# Cursor: line 1 = next page ("N" in-review, "aN" available), optional
# "phase=review|available" for the pending issues, then pending issue numbers.
# Process one page of pending issues, persisting the cursor before each issue.
# A deadline between issues retains every unstarted issue in the cursor.
# Args: $1=repo slug, $2=deadline epoch, $3=cursor file, $4=cursor token,
#       $5=phase of the pending issues, $6=newline-separated issue numbers
# Returns: 0 page done, 3 deadline reached, 1 on failure
_pmpc_process_page() {
	local repo_slug="$1" deadline="$2" cursor="$3" token="$4" pending_phase="$5" issues="$6"
	local remaining="$issues" issue_num=""
	local now_epoch
	printf '%s\nphase=%s\n%s\n' "$token" "$pending_phase" "$remaining" >"$cursor" || return 1
	while IFS= read -r issue_num; do
		[[ -n "$issue_num" ]] || continue
		now_epoch=$(date +%s) || return 1
		[[ "$now_epoch" -lt "$deadline" ]] || return 3
		# Advance past only the current issue before its potentially slow API reads.
		if [[ "$remaining" == *$'\n'* ]]; then
			remaining="${remaining#*$'\n'}"
		else
			remaining=""
		fi
		printf '%s\nphase=%s\n%s\n' "$token" "$pending_phase" "$remaining" >"$cursor" || return 1
		if [[ "$pending_phase" == available ]]; then
			_pmpc_restore_available_dispatch "$repo_slug" "$issue_num" || true
			continue
		fi
		_pmpc_revisit_in_review_issue "$repo_slug" "$issue_num" || return 1
	done <<<"$issues"
	return 0
}

# Args: $1=repo slug, $2=deadline epoch
# Returns: 0 at traversal end, 3 when more pages/time are needed, 1 on read failure
_pm_reconcile_partial_continuations() {
	local repo_slug="$1" deadline="$2"
	local cap="${PULSE_PARTIAL_RECONCILE_PAGE_SIZE:-10}" page=1 next_page=1 token="1"
	local cursor_dir="${PULSE_PARTIAL_RECONCILE_STATE_DIR:-${HOME}/.aidevops/cache/partial-continuation}"
	local cursor="" issues_json="" issues="" now_epoch="" count=0 merged_rc=0 merged_deadline=0
	local line="" loaded=0 phase="review" pending_phase="review" last_page=0 resumed=0
	local avail_phase="available" pages_done=0 max_pages="${PULSE_PARTIAL_RECONCILE_MAX_PAGES:-0}"
	[[ "$max_pages" =~ ^[0-9]+$ ]] || max_pages=0
	[[ "$repo_slug" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ && "$deadline" =~ ^[0-9]+$ ]] || return 1
	[[ "$cap" =~ ^[1-9][0-9]*$ && "$cap" -le 100 ]] || cap=10
	cursor="${cursor_dir}/${repo_slug//\//__}"
	mkdir -p "$cursor_dir" 2>/dev/null || return 1
	if [[ -r "$cursor" ]]; then
		while IFS= read -r line; do
			if [[ "$loaded" -eq 0 ]]; then
				token="$line"
				loaded=1
			elif [[ "$line" =~ ^phase=(review|available)$ ]]; then
				pending_phase="${line#phase=}"
			elif [[ "$line" =~ ^[0-9]+$ ]]; then
				issues="${issues}${issues:+$'\n'}${line}"
			fi
		done <"$cursor"
	fi
	if [[ "$token" == a* ]]; then
		phase="$avail_phase"
		page="${token#a}"
	else
		page="$token"
	fi
	[[ "$page" =~ ^[1-9][0-9]*$ ]] || page=1
	now_epoch=$(date +%s) || return 1
	[[ "$now_epoch" -lt "$deadline" ]] || return 3
	merged_deadline=$((now_epoch + (deadline - now_epoch + 1) / 2))
	_pmpc_reconcile_recent_merges "$repo_slug" "$merged_deadline" || merged_rc=$?
	_pmpc_reconcile_closed_checkpoints "$repo_slug" "$deadline" "${phase}:${page}:${issues:+pending}" || true
	while true; do
		if [[ -z "$issues" ]]; then
			issues_json=$(_pmpc_list_candidates "$repo_slug" "$phase" "$page" "$cap") || return 1
			count="${issues_json%%$'\n'*}"
			issues="${issues_json#*$'\n'}"
			[[ "$issues" != "$issues_json" ]] || issues=""
			[[ "$count" =~ ^[0-9]+$ ]] || return 1
			last_page=1
			next_page="$page"
			if [[ "$count" -ge "$cap" ]]; then
				next_page=$((page + 1))
				last_page=0
			fi
			pending_phase="$phase"
		else
			# Resume the pending suffix; the token already names the next page.
			next_page="$page"
			last_page=0
			phase="$pending_phase"
			resumed=1
		fi
		# Persist the next page, the available-phase start or a reset; a resumed suffix keeps its token.
		if [[ "$resumed" -eq 1 ]]; then
			resumed=0
		elif [[ "$last_page" -eq 1 && "$phase" == review ]]; then
			token="a1"
		elif [[ "$last_page" -eq 1 ]]; then
			token="1"
		elif [[ "$phase" == available ]]; then
			token="a${next_page}"
		else
			token="${next_page}"
		fi
		_pmpc_process_page "$repo_slug" "$deadline" "$cursor" "$token" "$pending_phase" "$issues" || return $?
		issues=""
		if [[ "$token" == a1 && "$phase" == review ]]; then
			phase="$avail_phase"
			pending_phase="$avail_phase"
			page=1
			now_epoch=$(date +%s) || return 1
			[[ "$now_epoch" -lt "$deadline" ]] || return 3
			continue
		fi
		# GH#38677: the available phase's last page resets the token to "1".
		[[ "$token" != "1" ]] || break
		# More pages remain: keep going while time and the optional page budget allow.
		pages_done=$((pages_done + 1))
		if [[ "$max_pages" -gt 0 && "$pages_done" -ge "$max_pages" ]]; then
			return 3
		fi
		now_epoch=$(date +%s) || return 1
		[[ "$now_epoch" -lt "$deadline" ]] || return 3
		page="$next_page"
	done
	[[ "$token" == "1" ]] || return 3
	[[ "$merged_rc" -eq 0 ]] || return "$merged_rc"
	return 0
}
