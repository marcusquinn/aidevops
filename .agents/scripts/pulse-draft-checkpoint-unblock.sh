#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# pulse-draft-checkpoint-unblock.sh — GH#36028: return an issue that a worker
# release projected status:blocked while its draft PR stayed open to
# status:available, so the existing WORKER_DRAFT_CHECKPOINT dispatch route
# (pr-checkpoint-continuation-helper.sh dispatch-stalled) continues the exact
# draft head or records attention.
#
# Before v3.39.89 (GH#36019) a clean/worker_complete release with an open
# draft projected status:blocked. The dispatch candidate filter skips
# status:blocked and the stale-blocked sweep resolves only dependency blocks,
# so those drafts were never continued, merged or surfaced. Runners on older
# versions keep producing that state until they update.
#
# Every write requires trusted evidence that the block is that projection and
# nothing else; any unreadable or ambiguous read means no write:
#   - an open issue whose only status label is status:blocked, without a
#     protective label;
#   - exactly one open origin:worker draft PR closing it;
#   - the newest trusted CLAIM_RELEASED carries a continuable, non-terminal
#     reason, and no claim or live lease follows it;
#   - the newest `labeled status:blocked` event is that runner's, inside the
#     release projection window;
#   - assignees are only that runner;
#   - no audit marker exists for that release and the per-PR cap is unmet.
#
# Sourced by pulse-merge.sh. Reuses pulse-merge-partial-continuation.sh
# (trusted-comment jq definitions, bounded reads, owned assignees) and the
# shared set_issue_status / gh_issue_comment wrappers.

[[ -n "${_PULSE_DRAFT_CHECKPOINT_UNBLOCK_LOADED:-}" ]] && return 0
_PULSE_DRAFT_CHECKPOINT_UNBLOCK_LOADED=1

_pdcu_dir="${BASH_SOURCE[0]%/*}"
[[ "$_pdcu_dir" == "${BASH_SOURCE[0]}" ]] && _pdcu_dir="."
# shellcheck source=./pulse-merge-partial-continuation.sh
# shellcheck disable=SC1091  # sibling module resolved at runtime
source "${_pdcu_dir}/pulse-merge-partial-continuation.sh"
unset _pdcu_dir

_PDCU_MARKER_KIND="draft-checkpoint-unblock"
# Continuable release reasons: pr-checkpoint-continuation-helper.sh
# _PCC_STALL_RELEASE_PATTERN without the classes that keep or transfer
# ownership. Terminal-blocker classes stay held (GH#34775); ownership loss
# preserves a live owner.
_PDCU_RELEASE_REASON_PATTERN='^(no_activity|wall_clock_stale|stale_assignment_reset|worker_draft_checkpoint|clean|worker_complete|watchdog_kill:[A-Za-z0-9_.:-]+|[a-z0-9_]*_stall|[a-z0-9_]*timeout[a-z0-9_]*)$'
_PDCU_HELD_REASON_PATTERN='^(blocked|push_policy_timeout|network_policy_timeout|worker_ownership_lost)$'
# A claim or a non-terminal lease after the release means a newer owner.
_PDCU_OWNER_EVENT_PATTERN='(^|\n)(DISPATCH_CLAIM |DISPATCH_LEASE phase=(?!terminal )|Dispatching worker|(> )?Interactive session claimed)'
# `items(what)` accepts one REST page or `gh api --paginate --slurp` pages and
# fails on any other shape, so an unreadable list never reads as empty.
_PDCU_LIST_JQ_DEFS='
	def items(what): if type != "array" then error("unreadable " + what)
		elif (.[0]? | type) == "array" then [.[][]] else . end;
'

#######################################
# List open auto-dispatch issues whose only status label is status:blocked and
# that carry no protective label. Without auto-dispatch, status:available would
# not route the draft to continuation, so those issues are left unchanged.
# Args: $1=repo slug
# Stdout: one issue JSON object per line
# Returns: 0 on a readable list (possibly empty), 1 otherwise
#######################################
_pdcu_blocked_issues() {
	local repo_slug="$1"
	local issues_json=""
	issues_json=$(_pmpc_gh_read api "repos/${repo_slug}/issues?state=open&labels=status%3Ablocked&per_page=100" \
		--paginate --slurp 2>/dev/null) || return 1
	printf '%s' "$issues_json" | jq -c "${_PDCU_LIST_JQ_DEFS}"'
		def names: [.labels[]? | if type == "string" then . else (.name // empty) end];
		items("issues")[]
		| select(.pull_request == null and ((.number | type) == "number"))
		| select([names[] | select(startswith("status:"))] == ["status:blocked"])
		| select(names | index("auto-dispatch"))
		| select(names | any(. == "hold-for-review" or . == "no-auto-dispatch"
			or . == "needs-maintainer-review" or . == "needs-maintainer-permissions"
			or . == "persistent" or . == "parent-task") | not)
	' 2>/dev/null || return 1
	return 0
}

#######################################
# Map open origin:worker draft PRs to the issues they close.
# Args: $1=repo slug
# Stdout: "issue<TAB>pr<TAB>head_sha" per closing reference
# Returns: 0 on a readable list, 1 otherwise
#######################################
_pdcu_draft_closing_refs() {
	local repo_slug="$1"
	local prs_json=""
	prs_json=$(_pmpc_gh_read api "repos/${repo_slug}/pulls?state=open&per_page=100" \
		--paginate --slurp 2>/dev/null) || return 1
	printf '%s' "$prs_json" | jq -r --arg slug "$repo_slug" "${_PDCU_LIST_JQ_DEFS}"'
		($slug | ascii_downcase | gsub("[.]"; "\\.")) as $slug_re
		| ("(^|[^a-z0-9_])(close[ds]?|fix(es|ed)?|resolve[ds]?)[\\s:]+((" + $slug_re
			+ ")?#|https?://github\\.com/" + $slug_re + "/issues/)(?<n>[0-9]+)") as $ref
		| items("PR list")[]
		| if (type != "object") or ((.number | type) != "number") then error("unreadable PR")
		else . end
		| select(.draft == true and .state == "open")
		| select(any(.labels[]?; .name == "origin:worker"))
		# GitHub only interprets closing keywords against the default branch.
		# Missing branch metadata cannot prove an effective closing reference.
		| select((.base.repo.default_branch | type) == "string")
		| select((.base.repo.default_branch | length) > 0)
		| select(.base.ref == .base.repo.default_branch)
		| . as $pr
		| [(.body // "") | ascii_downcase | match($ref; "g") | .captures[] | select(.name == "n") | .string]
		| unique[]
		| [., ($pr.number | tostring), ($pr.head.sha // "")] | @tsv
	' 2>/dev/null || return 1
	return 0
}

#######################################
# Read the release evidence from trusted issue comments.
# Args: $1=comments JSON (`gh api --paginate --slurp` pages), $2=PR number
# Stdout: "release_id<TAB>reason<TAB>runner<TAB>released_epoch<TAB>pr_markers<TAB>release_marked"
# Returns: 0 when the newest trusted CLAIM_RELEASED has no later owner event,
#          1 otherwise (including unreadable comments)
#######################################
_pdcu_release_evidence() {
	local comments_json="$1"
	local pr_number="$2"
	local evidence=""
	evidence=$(printf '%s' "$comments_json" | jq -r \
		--arg owner "$_PDCU_OWNER_EVENT_PATTERN" \
		--arg marker "kind=${_PDCU_MARKER_KIND} pr=${pr_number} " "${_PMPC_COMMENTS_JQ_DEFS}"'
		[comments[] | select(trusted)
			| {id: ((.id // 0) | tonumber? // 0), created_at, updated_at: (.updated_at // .created_at),
				login: (.user.login // ""), body: (.body // "")}]
		| sort_by(.created_at, .id) as $trusted
		| ([$trusted[] | select(.body | test("(^|\n)CLAIM_RELEASED reason="))] | last) as $release
		| if $release == null then empty
		elif any($trusted[]; [.created_at, .id] > [$release.created_at, $release.id]
			and (.body | test($owner))) then empty
		# An edited release is not the record the runner wrote.
		elif $release.updated_at != $release.created_at then empty
		else
			($release.body | capture("(^|\n)CLAIM_RELEASED reason=(?<reason>[^ \n]+)(?<rest>[^\n]*)")) as $line
			| (($line.rest | capture("(^| )runner=(?<r>[A-Za-z0-9._-]+(\\[bot\\])?)") | .r) // $release.login) as $runner
			# The poster must be the runner it names (GH#33850 attention rule).
			| select($runner == $release.login)
			| [($release.id | tostring), $line.reason, $runner,
				($release.created_at | fromdateiso8601 | tostring),
				([$trusted[] | select(.body | contains($marker))] | length | tostring),
				(any($trusted[]; .body | contains($marker + "release=" + ($release.id | tostring) + " ")) | tostring)]
			| @tsv
		end
	' 2>/dev/null) || return 1
	[[ -n "$evidence" ]] || return 1
	printf '%s' "$evidence"
	return 0
}

#######################################
# Prove the current status:blocked label came from the release projection.
# Args: $1=timeline JSON (`gh api --paginate --slurp` pages), $2=runner login,
#       $3=release epoch
# Returns: 0 when the newest `labeled status:blocked` event is the runner's
#          and falls inside the window, 1 otherwise
#######################################
_pdcu_block_from_release() {
	local timeline_json="$1"
	local runner_login="$2"
	local released_epoch="$3"
	local before="${PULSE_DRAFT_UNBLOCK_WINDOW_BEFORE_SECONDS:-60}"
	local after="${PULSE_DRAFT_UNBLOCK_WINDOW_AFTER_SECONDS:-600}"
	[[ "$before" =~ ^[0-9]+$ ]] || before=60
	[[ "$after" =~ ^[0-9]+$ ]] || after=600
	printf '%s' "$timeline_json" | jq -e --arg runner "$runner_login" \
		--argjson released "$released_epoch" --argjson before "$before" --argjson after "$after" \
		"${_PDCU_LIST_JQ_DEFS}"'
		[items("timeline")[] | select(.event == "labeled" and .label.name? == "status:blocked")]
		| sort_by(.created_at) | last
		| if . == null then false
		else (.actor.login // "") == $runner
			and ((.created_at | fromdateiso8601) - $released) >= (0 - $before)
			and ((.created_at | fromdateiso8601) - $released) <= $after
		end
	' >/dev/null 2>&1
	return $?
}

#######################################
# Build the audit comment.
# Args: $1=PR number, $2=release comment id, $3=release reason, $4=head SHA
# Stdout: comment body
# Returns: 0
#######################################
_pdcu_comment_body() {
	local pr_number="$1"
	local release_id="$2"
	local reason="$3"
	local head_sha="$4"
	printf '%s\n' "<!-- ops:start — workers: skip this comment, it is audit trail not implementation context -->
<!-- aidevops:ops kind=${_PDCU_MARKER_KIND} pr=${pr_number} release=${release_id} -->
Worker draft PR #${pr_number} (head \`${head_sha:-unknown}\`) is still open, but the \`${reason}\` release projected \`status:blocked\` with no terminal blocker (pre-GH#36019 projection). Restored \`status:available\` so Pulse continues the exact draft head through the bounded checkpoint continuation, or records attention when that is exhausted. The draft is preserved and still blocks duplicate dispatch.
<!-- ops:end -->"
	return 0
}

#######################################
# Post the audit comment once; after a failed write, re-read for the marker
# before one retry so a write that landed server-side is not duplicated.
# Args: $1=repo slug, $2=issue, $3=PR, $4=release id, $5=reason, $6=head SHA
# Returns: 0 when the marker comment exists, 1 otherwise
#######################################
_pdcu_post_audit_comment() {
	local repo_slug="$1" issue_num="$2" pr_number="$3" release_id="$4" reason="$5" head_sha="$6"
	local body="" comments_json="" verdict=""
	body=$(_pdcu_comment_body "$pr_number" "$release_id" "$reason" "$head_sha")
	gh_issue_comment "$issue_num" --repo "$repo_slug" --body "$body" >/dev/null 2>&1 && return 0
	comments_json=$(_pmpc_gh_read api "repos/${repo_slug}/issues/${issue_num}/comments?per_page=100" \
		--paginate --slurp 2>/dev/null) || return 1
	verdict=$(printf '%s' "$comments_json" | jq -r \
		--arg marker "kind=${_PDCU_MARKER_KIND} pr=${pr_number} release=${release_id} " "${_PMPC_COMMENTS_JQ_DEFS}"'
		[comments[] | select(trusted) | (.body // "") | contains($marker)]
		| if any then "present" else "absent" end
	' 2>/dev/null) || return 1
	[[ "$verdict" == "present" ]] && return 0
	[[ "$verdict" == "absent" ]] || return 1
	gh_issue_comment "$issue_num" --repo "$repo_slug" --body "$body" >/dev/null 2>&1 && return 0
	return 1
}

#######################################
# Log one decision for an issue.
# Args: $1=repo slug, $2=issue, $3=PR, $4=decision text
# Returns: 0
#######################################
_pdcu_log() {
	local repo_slug="$1" issue_num="$2" pr_number="$3" decision="$4"
	echo "[pulse-wrapper] ${_PDCU_MARKER_KIND}: #${issue_num} draft PR #${pr_number} in ${repo_slug} — ${decision} (GH#36028)" >>"${LOGFILE:-/dev/null}"
	return 0
}

#######################################
# Verify the evidence for one stranded issue and restore it.
# #aidevops:trust-boundary — only OWNER/MEMBER/COLLABORATOR comments count as
# release evidence, and the label actor must be that trusted release runner.
# Args: $1=repo slug, $2=issue JSON, $3=PR number, $4=PR head SHA
# Returns: 0 when restored, 1 when no write was made
#######################################
_pdcu_try_issue() {
	local repo_slug="$1" issue_json="$2" pr_number="$3" head_sha="$4"
	local issue_num="" comments_json="" evidence="" timeline_json="" assignees="" login=""
	local release_id="" reason="" runner="" released_epoch="" pr_markers="" release_marked=""
	local cap="${PULSE_DRAFT_UNBLOCK_MAX_PER_PR:-3}"
	local -a transition_args=() logins=()
	[[ "$cap" =~ ^[1-9][0-9]*$ ]] || cap=3
	issue_num=$(printf '%s' "$issue_json" | jq -r '.number') || return 1
	if ! comments_json=$(_pmpc_gh_read api "repos/${repo_slug}/issues/${issue_num}/comments?per_page=100" \
		--paginate --slurp 2>/dev/null); then
		_pdcu_log "$repo_slug" "$issue_num" "$pr_number" "kept blocked: comments unreadable"
		return 1
	fi
	if ! evidence=$(_pdcu_release_evidence "$comments_json" "$pr_number"); then
		_pdcu_log "$repo_slug" "$issue_num" "$pr_number" "kept blocked: no current trusted worker release"
		return 1
	fi
	IFS=$'\t' read -r release_id reason runner released_epoch pr_markers release_marked <<<"$evidence"
	# Tab is IFS whitespace, so an empty field would shift the rest: validate all.
	if [[ ! "$release_id" =~ ^[1-9][0-9]*$ || ! "$runner" =~ ^[A-Za-z0-9._-]+(\[bot\])?$ ||
		! "$released_epoch" =~ ^[0-9]+$ || ! "$pr_markers" =~ ^[0-9]+$ ||
		! "$release_marked" =~ ^(true|false)$ ]]; then
		_pdcu_log "$repo_slug" "$issue_num" "$pr_number" "kept blocked: release evidence unreadable"
		return 1
	fi
	if [[ ! "$reason" =~ $_PDCU_RELEASE_REASON_PATTERN || "$reason" =~ $_PDCU_HELD_REASON_PATTERN ]]; then
		_pdcu_log "$repo_slug" "$issue_num" "$pr_number" "kept blocked: release reason ${reason} is held or not continuable"
		return 1
	fi
	if [[ "$release_marked" == true || "$pr_markers" -ge "$cap" ]]; then
		_pdcu_log "$repo_slug" "$issue_num" "$pr_number" "kept blocked: already restored for release ${release_id} or per-PR cap ${cap} reached"
		return 1
	fi
	if ! timeline_json=$(_pmpc_gh_read api "repos/${repo_slug}/issues/${issue_num}/timeline?per_page=100" \
		--paginate --slurp 2>/dev/null); then
		_pdcu_log "$repo_slug" "$issue_num" "$pr_number" "kept blocked: timeline unreadable"
		return 1
	fi
	if ! _pdcu_block_from_release "$timeline_json" "$runner" "$released_epoch"; then
		_pdcu_log "$repo_slug" "$issue_num" "$pr_number" "kept blocked: status:blocked was not applied by the ${reason} release projection"
		return 1
	fi
	if ! assignees=$(_pmpc_owned_assignees "$issue_json" "$runner" ""); then
		_pdcu_log "$repo_slug" "$issue_num" "$pr_number" "kept blocked: assignee is not the releasing runner"
		return 1
	fi
	if [[ -n "$assignees" ]]; then
		IFS=',' read -r -a logins <<<"$assignees"
		for login in "${logins[@]}"; do
			[[ -n "$login" ]] && transition_args+=(--remove-assignee "$login")
		done
	fi
	if ! set_issue_status "$issue_num" "$repo_slug" available \
		${transition_args[@]+"${transition_args[@]}"} >/dev/null 2>&1; then
		_pdcu_log "$repo_slug" "$issue_num" "$pr_number" "status transition failed"
		return 1
	fi
	_pdcu_post_audit_comment "$repo_slug" "$issue_num" "$pr_number" "$release_id" "$reason" "$head_sha" ||
		_pdcu_log "$repo_slug" "$issue_num" "$pr_number" "restored but the audit comment did not land"
	_pdcu_log "$repo_slug" "$issue_num" "$pr_number" "restored status:available after ${reason} release ${release_id} by ${runner}"
	return 0
}

#######################################
# One bounded pass for a repository on the stale-blocked cadence.
# Costs one REST read when no issue qualifies, two when no draft matches.
# Args: $1=repo slug, $2=deadline epoch
# Returns: 0 when every candidate was visited, 3 when the deadline stopped
#          the pass, 1 when a listing was unreadable
#######################################
_pm_reconcile_draft_checkpoint_blocks() {
	local repo_slug="$1" deadline="$2"
	local issues="" refs="" issue_json="" issue_num="" matches="" pr_number="" head_sha="" now_epoch=""
	[[ "$repo_slug" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ && "$deadline" =~ ^[0-9]+$ ]] || return 1
	if ! issues=$(_pdcu_blocked_issues "$repo_slug"); then
		echo "[pulse-wrapper] ${_PDCU_MARKER_KIND}: ${repo_slug} — pass failed: blocked-issue listing unreadable (GH#36028)" >>"${LOGFILE:-/dev/null}"
		return 1
	fi
	[[ -n "$issues" ]] || return 0
	if ! refs=$(_pdcu_draft_closing_refs "$repo_slug"); then
		echo "[pulse-wrapper] ${_PDCU_MARKER_KIND}: ${repo_slug} — pass failed: open PR listing unreadable (GH#36028)" >>"${LOGFILE:-/dev/null}"
		return 1
	fi
	[[ -n "$refs" ]] || return 0
	while IFS= read -r issue_json; do
		[[ -n "$issue_json" ]] || continue
		issue_num=$(printf '%s' "$issue_json" | jq -r '.number') || continue
		matches=$(printf '%s\n' "$refs" | awk -F'\t' -v n="$issue_num" '$1 == n')
		[[ -n "$matches" ]] || continue
		# Several drafts claiming one issue are ambiguous: leave them alone.
		[[ "$matches" != *$'\n'* ]] || continue
		now_epoch=$(date +%s) || return 1
		[[ "$now_epoch" -lt "$deadline" ]] || return 3
		IFS=$'\t' read -r _ pr_number head_sha <<<"$matches"
		_pdcu_try_issue "$repo_slug" "$issue_json" "$pr_number" "$head_sha" || true
	done <<<"$issues"
	return 0
}
