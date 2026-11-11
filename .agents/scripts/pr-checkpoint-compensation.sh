#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Sourced by pr-checkpoint-continuation-helper.sh. Never launches a worker.

_pcc_compensation_file() {
	local repo="$1" pr="$2"
	printf '%s/%s-%s.compensation.json\n' "$STATE_DIR" "$(_prrts_safe_slug "$repo")" "$pr"
	return 0
}

# Freeze the post-restoration state. A retry is authorized only while this
# exact evidence remains unchanged, even if the original prelaunch TTL elapsed.
_pcc_compensation_snapshot() {
	local repo="$1" pr="$2" issue="$3" release="$4" terminal="$5" runner="$6"
	local pr_json="" issue_json="" events=""
	local comments=""
	pr_json=$(gh pr view "$pr" --repo "$repo" --json number,state,body,isDraft,isCrossRepository,labels,headRefName,headRefOid,author,closingIssuesReferences) || return 1
	issue_json=$(gh api "repos/${repo}/issues/${issue}") || return 1
	comments=$(_pcc_issue_comments "$repo" "$issue") || return 1
	events=$(gh api "repos/${repo}/issues/${issue}/events?per_page=100" --paginate --slurp) || return 1
	printf '%s\n' "$pr_json" "$issue_json" "$comments" "$events" | jq -Ssc \
		--arg release "$release" --arg terminal "$terminal" --arg runner "$runner" '
		def published:
			.user.login == $runner and (.updated_at // .created_at) == .created_at and
			(.author_association | IN("OWNER", "MEMBER", "COLLABORATOR")) and
			(.body == $release or .body == $terminal);
		{pr:.[0], issue:(.[1] | {number,state,body,labels,assignees,updated_at}), events:(.[3] | flatten),
		 comments:([.[2] | flatten[] | select(published | not)] | sort_by(.id))}'
	return $?
}

#aidevops:trust-boundary — saved proof comes only from this dispatcher's
# exact-claim, never-launched fence; changed evidence never authorizes replay.
_pcc_retry_compensation() {
	local repo="$1" pr="$2" pending="" issue="" runner="" release="" terminal="" snapshot="" comments="" body=""
	pending=$(_pcc_compensation_file "$repo" "$pr") || return 1
	[[ -f "$pending" ]] || return 0
	[[ ! -L "$pending" ]] || return 1
	jq -e --arg repo "$repo" --argjson pr "$pr" \
		'.repo == $repo and .pr == $pr and (.issue | type == "number")' "$pending" >/dev/null || return 1
	issue=$(jq -r '.issue' "$pending") || return 1
	runner=$(jq -r '.runner' "$pending") || return 1
	[[ "$(gh api user --jq '.login')" == "$runner" ]] || return 1
	release=$(jq -r '.release' "$pending") || return 1
	terminal=$(jq -r '.terminal' "$pending") || return 1
	snapshot=$(_pcc_compensation_snapshot "$repo" "$pr" "$issue" "$release" "$terminal" "$runner") || return 1
	# Posting coordination comments itself updates issue.updated_at.
	jq -e --argjson snapshot "$snapshot" \
		'(.snapshot | del(.issue.updated_at)) == ($snapshot | del(.issue.updated_at))' "$pending" >/dev/null || {
		_prrts_log "dispatch: compensation held — saved target or claim evidence changed"
		return 1
	}
	for body in "$release" "$terminal"; do
		# An uncertain POST may already have succeeded. Reread before every retry.
		comments=$(_pcc_issue_comments "$repo" "$issue") || return 1
		if jq -e --arg body "$body" --arg runner "$runner" \
			'any(flatten[]; .body == $body and .user.login == $runner and (.updated_at // .created_at) == .created_at
			 and (.author_association | IN("OWNER", "MEMBER", "COLLABORATOR")))' <<<"$comments" >/dev/null; then
			continue
		fi
		gh api "repos/${repo}/issues/${issue}/comments" --method POST --field body="$body" >/dev/null || {
			_prrts_log "dispatch: compensation publication failed — retaining exact-claim retry state"
			return 1
		}
	done
	rm -f "$pending" || return 1
	return 0
}

_pcc_release_not_launched_claim() {
	local repo="$1" pr="$2" release="" terminal="" ts="" pending="" tmp="" snapshot=""
	ts=$(date -u +%Y-%m-%dT%H:%M:%SZ) || return 1
	release="CLAIM_RELEASED reason=worker_not_launched runner=${PCC_AUTHENTICATED_LOGIN} ts=${ts} claim_id=${AIDEVOPS_PR_CHECKPOINT_CLAIM_ID} nonce=${AIDEVOPS_DISPATCH_LEASE_TOKEN} lease_token=${AIDEVOPS_DISPATCH_LEASE_TOKEN} device=${AIDEVOPS_DISPATCH_LEASE_DEVICE} session=${AIDEVOPS_PR_CHECKPOINT_SESSION}"
	terminal="DISPATCH_LEASE phase=terminal lease_token=${AIDEVOPS_DISPATCH_LEASE_TOKEN} device=${AIDEVOPS_DISPATCH_LEASE_DEVICE} session=${AIDEVOPS_PR_CHECKPOINT_SESSION} expires_at=0 ts=${ts}"
	pending=$(_pcc_compensation_file "$repo" "$pr") || return 1
	# Never overwrite an unresolved episode with another claim's proof.
	[[ ! -e "$pending" ]] || return 1
	snapshot=$(_pcc_compensation_snapshot "$repo" "$pr" "$PCC_LINKED_ISSUE" "$release" "$terminal" "$PCC_AUTHENTICATED_LOGIN") || return 1
	# Validate the very evidence being persisted, not an earlier live read.
	_pcc_verify_untransferred_revision "$repo" "$pr" "$snapshot" || return 1
	_prrts_ensure_dirs
	tmp=$(mktemp "${pending}.XXXXXX") || return 1
	jq -n --arg repo "$repo" --argjson pr "$pr" --argjson issue "$PCC_LINKED_ISSUE" \
		--arg runner "$PCC_AUTHENTICATED_LOGIN" --arg release "$release" --arg terminal "$terminal" \
		--argjson snapshot "$snapshot" \
		'{repo:$repo,pr:$pr,issue:$issue,runner:$runner,release:$release,terminal:$terminal,snapshot:$snapshot}' >"$tmp" || return 1
	mv "$tmp" "$pending" || return 1
	_pcc_retry_compensation "$repo" "$pr"
	return $?
}

# A failed assignment request may not have changed ownership at all. Validate
# that actual state as a claiming snapshot, not as ownership by the successor.
_pcc_verify_untransferred_revision() {
	local repo="$1" pr="$2" snapshot="${3:-}" pr_json="" issue_json="" comments="" approval=""
	[[ "$AIDEVOPS_PR_CHECKPOINT_ADMISSION_MODE" == revision ]] || return 1
	if [[ -n "$snapshot" ]]; then
		pr_json=$(jq -c '.pr' <<<"$snapshot") || return 1
		issue_json=$(jq -c '.issue' <<<"$snapshot") || return 1
		comments=$(jq -c '.comments' <<<"$snapshot") || return 1
	else
		pr_json=$(gh pr view "$pr" --repo "$repo" --json number,state,body,isDraft,isCrossRepository,labels,headRefName,headRefOid,author,closingIssuesReferences) || return 1
		issue_json=$(gh api "repos/${repo}/issues/${PCC_LINKED_ISSUE}") || return 1
		comments=$(_pcc_issue_comments "$repo" "$PCC_LINKED_ISSUE") || return 1
	fi
	jq -e --arg owner "$PCC_PREVIOUS_ASSIGNEE" --argjson issue "$PCC_LINKED_ISSUE" \
		'.number == $issue and [.assignees[].login] == (if $owner == "" then [] else [$owner] end)' <<<"$issue_json" >/dev/null || return 1
	approval=$(AIDEVOPS_PR_CHECKPOINT_REQUIRE_PRELAUNCH=1 _pr_checkpoint_revised_target \
		"$repo" "$pr_json" "$issue_json" "$comments" "$PCC_AUTHENTICATED_LOGIN" \
		"$AIDEVOPS_DISPATCH_LEASE_TOKEN" "$AIDEVOPS_PR_CHECKPOINT_SESSION" true) || return 1
	jq -e --argjson pr "$pr" --argjson issue "$PCC_LINKED_ISSUE" --arg head "$PCC_HEAD_OID" \
		--arg ref "$PCC_HEAD_REF" --arg runner "$PCC_CHECKPOINT_ASSIGNEE" \
		'.pr == $pr and .issue == $issue and .head == $head and .ref == $ref and .runner == $runner' <<<"$approval" >/dev/null
	return $?
}
