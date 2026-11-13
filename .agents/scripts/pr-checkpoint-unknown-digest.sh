#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Sourced by pr-checkpoint-continuation-helper.sh. Never launches a worker.

# GH#36525: classification is not authority. A positive private-evidence triage
# on the releasing runner binds the original head and brief; all template and
# dispatch-approved checks still run. Never infer eligibility from draft prose.
_pcc_unknown_pending_work() {
	local repo="$1" issue="$2" pr="$3" head="$4" runner="$5" release="$6" attempt="$7" comments="$8"
	local issue_json='' pr_json='' brief='' marker='' approval='' login='' permission='' policy='' configured_by='' actor=''
	local registry="${AIDEVOPS_REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"
	local mode="${9:-route}"
	local issue_api="repos/${repo}/issues"
	marker=$(jq -er --argjson id "$release" --arg head "$head" '
		flatten[] | select(.id == $id and (.updated_at // .created_at) == .created_at) |
		select((.body // "") | test("(?m)^Terminal blocker: reason=unknown owner=worker-triage ")) |
		.body | split("\n")[] |
		capture("^CHECKPOINT_UNKNOWN_TRIAGE pending_work brief=(?<brief>[a-f0-9]{64}) head=(?<head>[a-f0-9]{40,64})$") |
		select(.head == $head) | .brief' <<<"$comments") || return 1
	[[ "$marker" =~ ^[a-f0-9]{64}$ ]] || return 1
	issue_json=$(gh api "${issue_api}/${issue}") || return 1
	pr_json=$(gh pr view "$pr" --repo "$repo" --json number,state,isDraft,isCrossRepository,labels,headRefName,headRefOid,author,body,closingIssuesReferences) || return 1
	_pr_checkpoint_pr_metadata_is_eligible "$pr_json" "$repo" "$pr" "$issue" "$head" "" "$runner" || return 1
	# #aidevops:trust-boundary — no live owner or protective hold may be approved.
	jq -e '.state == "open" and (.assignees | length) == 0 and
		any(.labels[]; .name == "auto-dispatch") and
		([.labels[].name | select(test("^(no-auto-dispatch|no-takeover|hold-for-review|needs-maintainer-.*|parent-task|persistent|status:(claimed|in-progress|queued|done))$"))] | length) == 0' <<<"$issue_json" >/dev/null || return 1
	brief=$(python3 -c 'import hashlib,json,sys; print(hashlib.sha256(json.load(sys.stdin)["body"].encode()).hexdigest())' <<<"$issue_json") || return 1
	[[ "$brief" == "$marker" ]] || return 1
	approval=$(_pcc_approval_template "$repo" "$pr" "$issue" "$release" "$attempt") || return 1
	# A template is also the ready-to-run digest command's validation. Check its
	# fresh binding: a head/body move during generation never receives approval.
	jq -e --arg head "$head" --arg brief "$brief" \
		'select(.head == $head and .brief_sha256 == $brief)' <<<"${approval#CHECKPOINT_CONTINUATION_APPROVED }" >/dev/null || return 1
	if [[ "$mode" == "digest-entry" ]]; then
		_pcc_unknown_digest_entry "$repo" "$issue" "$pr" "$head" "$release" "$attempt"
		return 0
	fi
	policy=$(jq -cer --arg repo "$repo" '[.initialized_repos[] | select(.slug == $repo)] |
		select(length == 1) | .[0].checkpoint_policy |
		select(.auto_continue_unknown_pending_work == true)' "$registry" 2>/dev/null) || policy=""
	if [[ -z "$policy" ]]; then
		_pcc_unknown_digest "$repo" "$issue" "$pr" "$head" "$release" "$attempt"
		return $?
	fi
	configured_by=$(jq -er '.configured_by' <<<"$policy") || return 1
	_pcc_login_is_safe "$configured_by" || return 1
	login=$(gh api user --jq '.login') || return 1
	_pcc_login_is_safe "$login" || return 1
	# Both the policy owner and publishing actor need current repository write
	# authority. Association labels and template generation grant none.
	for actor in "$configured_by" "$login" "$runner"; do
		permission=$(gh api "repos/${repo}/collaborators/${actor}/permission" --jq '.permission') || return 1
		case "$permission" in admin | maintain | write) ;; *) return 1 ;; esac
	done
	# Only an authoritative, unedited, unexpired full-envelope approval can
	# suppress publication; approval-looking text from a commenter grants nothing.
	if _pr_checkpoint_revised_target "$repo" "$pr_json" "$issue_json" "$comments" "" >/dev/null 2>&1; then
		return 0
	fi
	# Publish through the same signed wrapper used by a maintainer. No direct
	# dispatch, label change, claim transfer or security exemption is introduced.
	printf '%s\n' "$approval" | "${SCRIPT_DIR}/gh-write-helper.sh" issue comment "$issue" --repo "$repo" --body-file - >/dev/null || return 1
	printf 'UNKNOWN_CHECKPOINT_APPROVED pr=%s head=%s release=%s\n' "$pr" "$head" "$release"
	return 0
}

# Snapshot entries have passed the same fresh binding/template validation as
# policy routing. This output is informational, never an approval declaration.
_pcc_unknown_digest_entry() {
	local repo="$1" issue="$2" pr="$3" head="$4" release="$5" attempt="$6"
	# shellcheck disable=SC2016 # Markdown code span, not command substitution.
	printf -- '- PR #%s, issue #%s, head %s: `pr-checkpoint-continuation-helper.sh approval-template %s %s %s %s %s`\n' \
		"$pr" "$issue" "$head" "$repo" "$pr" "$issue" "$release" "$attempt"
	return 0
}

# Collect other eligible drafts for the daily snapshot, bounded by inventory
# limits and the existing gh transport budget. Late arrivals wait for tomorrow;
# snapshots are immutable so concurrent writers cannot overwrite their entries.
_pcc_unknown_digest_snapshot() {
	local repo="$1" first_issue="$2"
	local issues='' prs='' issue='' comments='' trusted='' rows='' pr='' head='' runner=''
	local evidence='' release='' attempt='' posted='' successor='' entry='' deadline=$((SECONDS + 40))
	issues=$(gh issue list --repo "$repo" --state open --label auto-dispatch --label status:blocked --limit 100 --json number,assignees) || return 1
	prs=$(gh pr list --repo "$repo" --state open --draft --label origin:worker --limit 100 --json number,headRefOid,author) || return 1
	while IFS= read -r issue; do
		[[ "$SECONDS" -lt "$deadline" ]] || break
		[[ "$issue" != "$first_issue" && "$issue" =~ ^[1-9][0-9]*$ ]] || continue
		comments=$(_pcc_issue_comments "$repo" "$issue") || continue
		trusted=$(_pr_checkpoint_trusted_logins "$comments" "$repo") || continue
		rows=$(jq -r --argjson prs "$prs" '
			[flatten[] | (.body // "") |
				split("\n")[] |
				capture("^CHECKPOINT_UNKNOWN_TRIAGE pending_work brief=[a-f0-9]{64} head=(?<head>[a-f0-9]{40,64})$")? | .head] |
			unique[] as $head | $prs[] | select(.headRefOid == $head) |
			[.number, .headRefOid, .author.login] | @tsv' <<<"$comments") || continue
		while IFS=$'\t' read -r pr head runner; do
			[[ "$SECONDS" -lt "$deadline" && -n "$pr" ]] || break
			evidence=$(_pcc_blocked_release_evidence "$comments" "$runner" "digest-snapshot" "$trusted") || continue
			IFS=$'\t' read -r release attempt posted successor <<<"$evidence"
			[[ "$successor" == '-' && "$attempt" == attempt:* ]] || continue
			entry=$(_pcc_unknown_pending_work "$repo" "$issue" "$pr" "$head" "$runner" "$release" "$attempt" "$comments" digest-entry) || continue
			printf '%s\n' "$entry"
		done <<<"$rows"
	done < <(jq -r '.[] | select((.assignees | length) == 0) | .number' <<<"$issues")
	return 0
}

# Native label creation is atomic across the fleet, unlike indexed search.
# The reservation label is never attached to an issue and changes no hold.
# Only its creator may POST the daily snapshot; an ambiguous POST is never
# retried, preserving at-most-once publication even after process/HTTP failure.
_pcc_unknown_digest() {
	local repo="$1" issue="$2" pr="$3" head="$4" release="$5" attempt="$6"
	local day='' label='' body='' entries='' snapshot=''
	day=$(date -u '+%Y-%m-%d')
	label="checkpoint-digest:${day}"
	# Avoid repeat create attempts/422s on every Pulse observation that day.
	if gh api "repos/${repo}/labels/${label}" >/dev/null 2>&1; then
		return 0
	fi
	if ! gh api "repos/${repo}/labels" --method POST -f name="$label" -f color=ededed \
		-f description="Unknown checkpoint snapshot reserved for issue #${issue}; no dispatch authority" >/dev/null 2>&1; then
		# A failed reservation is handled only when the shared record exists.
		# An outage/permission failure must not masquerade as a prior digest.
		gh api "repos/${repo}/labels/${label}" >/dev/null 2>&1 || return 1
		return 0
	fi
	entries=$(_pcc_unknown_digest_entry "$repo" "$issue" "$pr" "$head" "$release" "$attempt")
	snapshot=$(_pcc_unknown_digest_snapshot "$repo" "$issue") || snapshot=''
	printf -v body '%s\n\n%s\n\n%s\n%s' "UNKNOWN_CHECKPOINT_DIGEST day=${day}" \
		'Unknown blocked checkpoints positively classified as unfinished in-scope work. Automatic continuation is off. A write-authorised brief owner can run these validated commands and publish their revision-bound approval lines. This digest grants no approval. This bounded daily snapshot is immutable; later arrivals or unreadable candidates are reconsidered tomorrow. Commands revalidate their targets when run.' \
		"$entries" "$snapshot"
	printf '%s\n' "$body" | "${SCRIPT_DIR}/gh-write-helper.sh" issue comment "$issue" --repo "$repo" --body-file - >/dev/null || return 1
	printf 'UNKNOWN_CHECKPOINT_DIGEST_POSTED day=%s pr=%s\n' "$day" "$pr"
	return 0
}
