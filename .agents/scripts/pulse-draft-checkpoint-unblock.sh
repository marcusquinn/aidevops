#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# GH#36028: recover only a runner's non-blocking release projection, not holds.
# Sourced after pulse-merge-partial-continuation.sh (read and trusted jq helpers).

[[ -n "${_PULSE_DRAFT_CHECKPOINT_UNBLOCK_LOADED:-}" ]] && return 0
_PULSE_DRAFT_CHECKPOINT_UNBLOCK_LOADED=1

# Keep in sync with _PCC_STALL_RELEASE_PATTERN; the regression suite checks it.
# Do not source the executable continuation helper (it changes shell options).
_PDCU_RELEASE_PATTERN='^(no_activity|wall_clock_stale|stale_assignment_reset|worker_ownership_lost|worker_draft_checkpoint|clean|worker_complete|watchdog_kill:[A-Za-z0-9_.:-]+|[a-z0-9_]*_stall|[a-z0-9_]*timeout[a-z0-9_]*)$'
_PDCU_JQ_TYPES='def array: type == "array"; def string: type == "string"; def number: type == "number";'

_pdcu_before_deadline() {
	local deadline="$1" now=""
	now=$(date +%s) || return 1
	[[ "$now" -lt "$deadline" ]] || return 1
	return 0
}

# A missing label/assignee field is not evidence of an unprotected issue.
_pdcu_candidates() {
	local issues="$1"
	printf '%s' "$issues" | jq -c "${_PDCU_JQ_TYPES}"'
		def readable: type == "object" and (.number | number)
			and (.state | string) and (.labels | array)
			and all(.labels[]; (.name | string))
			and (.assignees | array)
			and all(.assignees[]; (.login | string) and .login != "");
		if (array | not) or (all(.[]; readable) | not) then error("unreadable issues")
		else .[] | select(.pull_request == null and .state == "open")
			| [.labels[].name] as $labels
			| select([$labels[] | select(startswith("status:"))] == ["status:blocked"])
			| select(any($labels[]; . == "hold-for-review" or . == "no-auto-dispatch"
				or . == "needs-maintainer-review" or . == "needs-maintainer-permissions"
				or . == "persistent" or . == "parent-task") | not) end
	'
	return $?
}

# Exactly one open worker draft must close the candidate. A full PR page cannot
# prove uniqueness beyond that page, so defer rather than make an unsafe write.
_pdcu_draft() {
	local prs="$1" issue="$2"
	printf '%s' "$prs" | jq -er --arg issue "$issue" "${_PDCU_JQ_TYPES}"'
		if (array | not) or length >= 100 or any(.[];
			(.number | number | not) or (.draft | type) != "boolean"
			or (has("body") | not) or (.body != null and (.body | string | not))
			or (.labels | array | not) or any(.labels[]; (.name | string | not)))
		then error("incomplete PR list") else . end
		| [.[] | select(.draft and any(.labels[]; .name == "origin:worker"))
			| select((.body // "") | test("(^|[^a-z0-9_])(close[ds]?|fix(es|ed)?|resolve[ds]?)[\\s:]+#"
				+ $issue + "([^0-9]|$)"; "i"))]
		| if length == 1 then .[0].number else empty end
	'
	return $?
}

# Output runner, release ID and assignees only for an unedited trusted release
# whose own runner applied the newest blocked label in [-60,+600] seconds.
# Every later trusted coordination event is a fence, including a live claim.
_pdcu_evidence() {
	local comments="$1" timeline="$2" issue="$3" pr="$4"
	printf '%s' "$comments" | jq -er --argjson timeline "$timeline" --argjson issue "$issue" \
		--arg pr "$pr" --arg pattern "$_PDCU_RELEASE_PATTERN" \
		--arg events "$_PMPC_EVENT_PATTERN" "${_PMPC_COMMENTS_JQ_DEFS}${_PDCU_JQ_TYPES}"'
		def pages: if (array | not) then error("unreadable timeline")
			elif (.[0]? | array) then [.[][]] else . end;
		def epoch: fromdateiso8601;
		[comments[] | select(trusted)] as $trusted
		| [$trusted[] | select((.body // "") | test($events))] as $events
		| if any($events[]; (.id | number | not) or (.user.login | string | not))
			then error("unreadable event") else . end
		| ($events | sort_by(.created_at, .id) | last) as $release
		| select($release != null and ($release.updated_at // $release.created_at) == $release.created_at)
		| ([$release.body | split("\n")[] | select(startswith("CLAIM_RELEASED "))]) as $lines
		| select(($lines | length) == 1)
		| ($lines[0] | capture("^CLAIM_RELEASED reason=(?<reason>[^ \\r]+)( |$)")) as $reason
		| select($reason.reason | test($pattern))
		| select(["blocked", "push_policy_timeout", "network_policy_timeout", "worker_ownership_lost"]
			| index($reason.reason) | not)
		| ($lines[0] | capture("(^| )runner=(?<runner>[A-Za-z0-9._-]+(\\[bot\\])?)([ \\r]|$)")) as $owner
		| select($owner.runner == $release.user.login)
		| ("kind=draft-checkpoint-unblock pr=" + $pr + " release=") as $marker
		| select([$trusted[] | select((.body // "") | contains($marker))] | length < 3)
		| select(any($trusted[]; (.body // "") | contains($marker + ($release.id | tostring) + " -->")) | not)
		| select(all($issue.assignees[]; .login == $owner.runner))
		| ($timeline | pages) as $history
		| if any($history[]; type != "object" or (.event | string | not))
			then error("unreadable timeline event") else . end
		| [$history[] | select(.event == "labeled")
			| if (.label.name | string | not) then error("unreadable label") else . end
			| select(.label.name == "status:blocked")
			| if (.created_at | string | not) or (.actor.login | string | not)
				then error("unreadable label actor") else . end] as $blocks
		| ($blocks | sort_by(.created_at, .id) | last) as $block
		| select($block != null and $block.actor.login == $owner.runner)
		| (($block.created_at | epoch) - ($release.created_at | epoch)) as $delta
		| select($delta >= -60 and $delta <= 600)
		| [$owner.runner, ($release.id | tostring), ([$issue.assignees[].login] | join(","))] | @tsv
	' 2>/dev/null
	return $?
}

# One page each of issues/PRs; no per-issue reads when no pair matches.
# Returns 0 when complete, 3 at deadline, 1 for failed reads/writes.
_pm_reconcile_draft_checkpoint_unblocks() {
	local repo="$1" deadline="$2"
	local issues="" candidates="" prs="" issue="" number="" pr="" comments="" timeline=""
	local evidence="" runner="" release="" assignees="" body="" read_rc=0
	local -a args=()
	[[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ && "$deadline" =~ ^[0-9]+$ ]] || return 1
	_pdcu_before_deadline "$deadline" || return 3
	issues=$(_pmpc_gh_read api "repos/${repo}/issues?state=open&labels=status%3Ablocked&per_page=100" 2>/dev/null) || return 1
	candidates=$(_pdcu_candidates "$issues") || return 1
	[[ -n "$candidates" ]] || return 0
	_pdcu_before_deadline "$deadline" || return 3
	prs=$(_pmpc_gh_read api "repos/${repo}/pulls?state=open&per_page=100" 2>/dev/null) || return 1
	# Validate even when no draft matches (and never mistake a failed read for []).
	printf '%s' "$prs" | jq -e 'type == "array" and length < 100' >/dev/null 2>&1 || return 1
	while IFS= read -r issue; do
		_pdcu_before_deadline "$deadline" || return 3
		number=$(printf '%s' "$issue" | jq -r '.number') || return 1
		read_rc=0
		pr=$(_pdcu_draft "$prs" "$number") || read_rc=$?
		# jq -e returns 4 for a valid empty selection, 5 for unreadable data.
		[[ "$read_rc" -ne 4 ]] || continue
		[[ "$read_rc" -eq 0 ]] || return 1
		_pdcu_before_deadline "$deadline" || return 3
		comments=$(_pmpc_gh_read api "repos/${repo}/issues/${number}/comments?per_page=100" --paginate --slurp 2>/dev/null) || return 1
		_pdcu_before_deadline "$deadline" || return 3
		timeline=$(_pmpc_gh_read api "repos/${repo}/issues/${number}/timeline?per_page=100" --paginate --slurp 2>/dev/null) || return 1
		read_rc=0
		evidence=$(_pdcu_evidence "$comments" "$timeline" "$issue" "$pr") || read_rc=$?
		[[ "$read_rc" -ne 4 ]] || continue
		[[ "$read_rc" -eq 0 ]] || return 1
		IFS=$'\t' read -r runner release assignees <<<"$evidence"
		args=()
		[[ -z "$assignees" ]] || args+=(--remove-assignee "$runner")
		_pdcu_before_deadline "$deadline" || return 3
		set_issue_status "$number" "$repo" available ${args[@]+"${args[@]}"} >/dev/null 2>&1 || return 1
		body="<!-- aidevops:ops kind=draft-checkpoint-unblock pr=${pr} release=${release} -->
Restored status:available and released the runner assignment: the newest trusted non-blocking release projected status:blocked while worker draft #${pr} remains open. Existing exact-head continuation and attention guards still apply. (GH#36028)"
		_pdcu_before_deadline "$deadline" || return 3
		if ! gh_issue_comment "$number" --repo "$repo" --body "$body" >/dev/null 2>&1; then
			printf '[pulse-wrapper] draft-checkpoint-unblock issue=%s pr=%s release=%s audit=failed\n' "$number" "$pr" "$release" >>"$LOGFILE"
			return 1
		fi
		printf '[pulse-wrapper] draft-checkpoint-unblock issue=%s pr=%s release=%s status=available\n' "$number" "$pr" "$release" >>"$LOGFILE"
	done <<<"$candidates"
	return 0
}
