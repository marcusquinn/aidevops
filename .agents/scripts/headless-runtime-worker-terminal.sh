#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Headless Runtime Worker Terminal -- PR-less terminal completion verdicts
# =============================================================================
# Sourced by headless-runtime-worker.sh after its constants and dependencies.
# Function bodies are kept unchanged; callers continue to source the worker
# orchestrator, which supplies claim lifecycle and PR handoff helpers.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_HEADLESS_RUNTIME_WORKER_TERMINAL_LIB_LOADED:-}" ]] && return 0
_HEADLESS_RUNTIME_WORKER_TERMINAL_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback for direct sourcing and test harnesses
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

#######################################
# Return success when GitHub already shows the worker target as terminal.
#
# A worker can be interrupted after it merged a PR and the linked issue closed.
# In that case the local process lacks a completion signal, but redispatching is
# noise. Only confirmed terminal GitHub state returns 0; unknown/API failures
# return 1 so normal failure handling remains conservative.
#
# Args: $1=session_key, $2=work_dir (optional, used to resolve branch)
#######################################
_worker_external_terminal_complete() {
	local session_key="$1"
	local work_dir="$2"
	local repo_slug="${DISPATCH_REPO_SLUG:-}"
	local issue_number=""

	[[ "$session_key" == issue-* ]] || return 1
	[[ -n "$repo_slug" ]] || return 1

	if [[ "$session_key" =~ ([0-9]+)$ ]]; then
		issue_number="${BASH_REMATCH[1]}"
	fi
	[[ -n "$issue_number" ]] || return 1
	command -v gh >/dev/null 2>&1 || return 1

	local issue_state=""
	issue_state=$(gh issue view "$issue_number" --repo "$repo_slug" --json state --jq '.state // empty' 2>/dev/null || true)
	[[ "$issue_state" == "CLOSED" ]] || return 1
	if _hrw_pr_less_terminal_complete "$session_key" "$work_dir" "$issue_number" "$repo_slug"; then
		return 0
	fi

	local branch_name="${WORKER_TARGET_BRANCH:-}"
	if [[ -n "$work_dir" && -d "$work_dir" ]]; then
		local live_branch_name=""
		live_branch_name=$(git -C "$work_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
		if [[ -n "$live_branch_name" && "$live_branch_name" != "$_HRW_GIT_HEAD" ]]; then
			branch_name="$live_branch_name"
		fi
	fi
	[[ -n "$branch_name" && "$branch_name" != "$_HRW_GIT_HEAD" ]] || return 1

	local branch_pr_numbers=""
	branch_pr_numbers=$(gh pr list --repo "$repo_slug" --head "$branch_name" --state merged --json number --jq '.[].number' 2>/dev/null || true)
	[[ -n "$branch_pr_numbers" ]] || return 1

	local issue_pr_numbers=""
	issue_pr_numbers=$(gh pr list --repo "$repo_slug" --state merged --search "$issue_number" --json number --jq '.[].number' 2>/dev/null || true)
	[[ -n "$issue_pr_numbers" ]] || return 1

	local branch_pr_number=""
	local padded_issue_prs=$'\n'"$issue_pr_numbers"$'\n'
	while IFS= read -r branch_pr_number; do
		[[ -n "$branch_pr_number" ]] || continue
		if [[ "$padded_issue_prs" == *$'\n'"$branch_pr_number"$'\n'* ]]; then
			print_info "[lifecycle] worker_external_terminal complete session=${session_key} issue=${issue_number} branch=${branch_name} pr=${branch_pr_number}"
			return 0
		fi
	done <<<"$branch_pr_numbers"

	return 1
}

# GH#35629: own squash merges need exact PR-head proof, not ancestry against
# the default tip. Keep this separate from the stricter PR-less contract.
# A finalized guarded receipt binds delivery to this session and attempt window.
_hrw_own_merged_terminal_complete() {
	local session_key="$1" work_dir="$2"
	_hrw_merged_terminal_complete "$session_key" "$work_dir" own
	return $?
}

# GH#37098: a read-only continuation may finish verification after an earlier
# attempt merged this exact head. This is delivery evidence, not merge ownership.
_hrw_continued_merged_terminal_complete() {
	local session_key="$1" work_dir="$2"
	_hrw_merged_terminal_complete "$session_key" "$work_dir" continuation
	return $?
}

_hrw_merged_terminal_complete() {
	local session_key="$1"
	local work_dir="$2"
	local mode="$3"
	local runtime_session="${discovered_session:-${_HRW_OWN_MERGED_RUNTIME_SESSION:-}}"
	local repo_slug="${DISPATCH_REPO_SLUG:-${WORKER_REPO_SLUG:-}}"
	local issue_number branch head dirty context started
	[[ -n "$runtime_session" && -n "${AIDEVOPS_ATTEMPT_ID:-}" ]] || return 1
	[[ "${AIDEVOPS_ATTEMPT_STARTED_AT:-}" =~ ^[0-9]{19}$ ]] || return 1
	_hrw_is_issue_worker_session "$session_key" || return 1
	issue_number=$(_hrw_issue_number_for_session "$session_key") || return 1
	[[ "$issue_number" =~ ^[1-9][0-9]*$ && "$repo_slug" == */* ]] || return 1
	[[ "${WORKER_ISSUE_NUMBER:-}" == "$issue_number" && -d "$work_dir" ]] || return 1
	work_dir=$(cd "$work_dir" && pwd -P) || return 1
	branch=$(git -C "$work_dir" branch --show-current 2>/dev/null) || return 1
	head=$(git -C "$work_dir" rev-parse HEAD 2>/dev/null) || return 1
	dirty=$(_hrw_task_worktree_status "$work_dir") || return 1
	[[ -n "$branch" && "$head" =~ ^[0-9a-f]{40}$ && -z "$dirty" ]] || return 1
	# A clean checkout at the delivered head cannot hide newer remote-only work.
	local remote_branch=""
	remote_branch=$(git -C "$work_dir" ls-remote origin "refs/heads/${branch}" 2>/dev/null) || return 1
	[[ -z "$remote_branch" || "${remote_branch%%[[:space:]]*}" == "$head" ]] || return 1
	context="${mode}|${session_key}|${repo_slug}|${issue_number}|${AIDEVOPS_ATTEMPT_ID}|${AIDEVOPS_ATTEMPT_STARTED_AT}|${runtime_session}|${work_dir}|${branch}|${head}"
	# Reuse only in-process proof for the identical attempt and clean head. A
	# later API outage must not erase verified delivery during finalization.
	[[ "$context" == "${_HRW_OWN_MERGED_VERIFIED_CONTEXT:-}" ]] && return 0
	started="${AIDEVOPS_ATTEMPT_STARTED_AT:0:10}"
	local issue_json handoff pr_number pr_json receipt
	issue_json=$(gh api "repos/${repo_slug}/issues/${issue_number}" 2>/dev/null) || return 1
	jq -e --arg closed closed --arg completed completed \
		'.state == $closed and .state_reason == $completed and .pull_request == null' \
		<<<"$issue_json" >/dev/null 2>&1 || return 1
	handoff=$(_pr_handoff_state_for_branch_or_issue "$branch" "$issue_number" \
		"$repo_slug" head-only "$head" 1) || return 1
	[[ "$handoff" =~ ^merged\|[1-9][0-9]*$ ]] || return 1
	pr_number="${handoff#*|}"
	# Bypass cached views and revalidate actual closing references, repository,
	# branch and head rather than trusting a search match or a prose summary.
	pr_json=$(AIDEVOPS_GH_PR_VIEW_CACHE_DISABLE=1 gh pr view "$pr_number" --repo "$repo_slug" \
		--json number,state,mergedAt,mergeCommit,headRefOid,headRefName,headRepository,headRepositoryOwner,closingIssuesReferences 2>/dev/null) || return 1
	jq -e --argjson pr "$pr_number" --argjson issue "$issue_number" \
		--arg repo "$repo_slug" --arg branch "$branch" --arg head "$head" \
		--arg separator / --arg string_type string --argjson started "$started" --arg mode "$mode" '
		.number == $pr and .state == "MERGED"
		and ((.mergedAt | fromdateiso8601) as $merged
			# GitHub timestamps have whole-second precision: equality cannot
			# establish own-attempt ordering, so classify it as continuation.
			| if $mode == "own" then $merged > $started else $merged <= $started end)
		and (.mergeCommit.oid | type == $string_type and test("^[0-9a-f]{40}$"))
		and .headRefOid == $head and .headRefName == $branch
		and ([.headRepositoryOwner.login, .headRepository.name] | join($separator) | ascii_downcase) == ($repo | ascii_downcase)
		and any(.closingIssuesReferences[]?; .number == $issue
			and ([.repository.owner.login, .repository.name] | join($separator) | ascii_downcase) == ($repo | ascii_downcase))
	' <<<"$pr_json" >/dev/null 2>&1 || return 1
	# Own-attempt receipts must be fresh for this attempt. For a continuation,
	# retain the same runtime owner's finalized receipt, fresh for the actual
	# merge; revalidate live issue/PR/head evidence in every new attempt. Never
	# rewrite that historical receipt or attribute its merge to this attempt.
	if [[ "$mode" == continuation ]]; then
		started=$(jq -r '.mergedAt | fromdateiso8601' <<<"$pr_json") || return 1
	fi
	receipt=$(_full_loop_cleanup_receipt_path "$repo_slug" "$pr_number") || return 1
	[[ -f "$receipt" && ! -L "$receipt" ]] || return 1
	jq -e --arg repo "$repo_slug" --argjson pr "$pr_number" --arg worktree "$work_dir" \
		--arg branch "$branch" --arg session "$runtime_session" --argjson started "$started" \
		--arg deferred "$_FULL_LOOP_CLEANUP_DEFERRED" --arg leased "$_FULL_LOOP_CLEANUP_LEASED" --arg string_type string '
		.schema_version == 1 and .repository == $repo and .pr_number == $pr
		and .worktree == $worktree and .branch == $branch and .owner.session == $session
		and (.owner.pid | type == "number" and . > 0)
		and (.owner.process_identity | type == $string_type and length > 0)
		# Cleanup receipts use Python ISO timestamps with fractional seconds;
		# jq fromdateiso8601 accepts only whole-second UTC timestamps.
		and (.created_at | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) >= $started
		and .executor_completion_state == "COMPLETE"
		and (.resource_cleanup_state == $deferred or .resource_cleanup_state == $leased)
		and (.release_status == "not-requested" or .release_status == "published" or .release_status == "superseded")
	' "$receipt" >/dev/null 2>&1 || return 1
	_HRW_OWN_MERGED_VERIFIED_CONTEXT="$context"
	_HRW_OWN_MERGED_RUNTIME_SESSION="$runtime_session"
	print_info "[lifecycle] worker_merged_${mode} complete session=${session_key} attempt=${AIDEVOPS_ATTEMPT_ID} issue=${issue_number} pr=${pr_number} head=${head}"
	return 0
}

# Task-owned worktree status for completion proofs. GH#37597: after the
# worker's own PR merges, full-loop-helper.sh writes the untracked deferred
# cleanup marker; reading it as unpublished work rejected verified delivery and
# resumed a finished session. Every other untracked or modified path still
# counts, so genuine post-merge edits keep failing closed.
# Args: $1 = worktree path
# Stdout: porcelain status (empty when clean)
_hrw_task_worktree_status() {
	local work_dir="$1"
	git -C "$work_dir" status --porcelain --untracked-files=all -- ":/" \
		"$_HRW_DEFERRED_CLEANUP_EXCLUDE_PATHSPEC" 2>/dev/null || return 1
	return 0
}

_hrw_terminal_objective_complete() {
	local session_key="$1"
	local work_dir="$2"
	_hrw_own_merged_terminal_complete "$session_key" "$work_dir" && return 0
	_hrw_continued_merged_terminal_complete "$session_key" "$work_dir" && return 0
	_hrw_pr_less_terminal_complete "$session_key" "$work_dir" \
		"$(_hrw_issue_number_for_session "$session_key")" "${DISPATCH_REPO_SLUG:-}" && return 0
	return 1
}

# PR-less objectives with a trusted terminal contract: explicit data-only work,
# pulse consolidation children, or work already delivered by a closing merged
# PR (GH#33672). The issue is fetched
# once and shared so ordinary open-issue finishes cost a single API read.
_hrw_pr_less_terminal_complete() {
	local session_key="$1"
	local work_dir="$2"
	local issue_number="$3"
	local repo_slug="$4"
	# Internal constant predicate names only: never retain API output or prose.
	_HRW_PR_LESS_REJECTION="invalid_context"
	# Set only by a contract the trusted issue explicitly opted into (GH#40048).
	_HRW_PR_LESS_OPTED_REJECTION=""
	_HRW_REVIEW_TRIAGE_VERIFIED=""
	_HRW_REVIEW_TRIAGE_CANDIDATE=""
	[[ "$issue_number" =~ ^[1-9][0-9]*$ && "$repo_slug" == */* ]] || return 1
	[[ "${WORKER_ISSUE_NUMBER:-$issue_number}" == "$issue_number" ]] || return 1
	[[ -d "$work_dir" ]] || return 1
	# Keep proven terminal state through finalization if a later API read fails.
	# Bind it to this attempt's exact local context and recheck for new edits.
	local head="" branch="" context="" task_status=""
	head=$(git -C "$work_dir" rev-parse HEAD 2>/dev/null) || head=""
	branch=$(git -C "$work_dir" branch --show-current 2>/dev/null) || branch=""
	if [[ -n "$head" && -n "$branch" ]]; then
		context="${session_key}|${repo_slug}|${issue_number}|${work_dir}|${branch}|${head}|${AIDEVOPS_ATTEMPT_ID:-}|${AIDEVOPS_ATTEMPT_STARTED_AT:-}"
		if [[ "$context" == "${_HRW_PR_LESS_VERIFIED_CONTEXT:-}" ]]; then
			_HRW_PR_LESS_REJECTION="worktree_status_unavailable"
			task_status=$(_hrw_task_worktree_status "$work_dir") || return 1
			if [[ -z "$task_status" ]]; then
				_HRW_PR_LESS_REJECTION=""
				return 0
			fi
			_HRW_PR_LESS_REJECTION="unpublished_worktree_changes"
			return 1
		fi
	fi
	local issue_json=""
	_HRW_SCOPED_DELIVERY_RECEIPT=""
	_HRW_PR_LESS_REJECTION="issue_evidence_unavailable"
	issue_json=$(gh api "repos/${repo_slug}/issues/${issue_number}" 2>/dev/null) || return 1
	# Detect the shape before closure/trust checks: neither an open issue nor a
	# spoofed author may fall back to a bare completion token after rejection.
	if jq -e '.body // "" | startswith("## Unactioned Review Feedback\n")' \
		<<<"$issue_json" >/dev/null 2>&1; then
		_HRW_REVIEW_TRIAGE_CANDIDATE=1
	fi
	_HRW_PR_LESS_REJECTION="issue_not_closed"
	jq -e '.state == "closed"' <<<"$issue_json" >/dev/null 2>&1 || return 1
	if _hrw_data_only_terminal_complete "$session_key" "$work_dir" "$issue_number" "$repo_slug" "$issue_json" ||
		_hrw_report_only_terminal_complete "$session_key" "$work_dir" "$issue_number" "$repo_slug" "$issue_json" ||
		_hrw_consolidation_terminal_complete "$session_key" "$work_dir" "$issue_number" "$repo_slug" "$issue_json" ||
		_hrw_already_delivered_terminal_complete "$session_key" "$work_dir" "$issue_number" "$repo_slug" "$issue_json" ||
		_hrw_already_satisfied_terminal_complete "$session_key" "$work_dir" "$issue_number" "$repo_slug" "$issue_json" ||
		_hrw_review_triage_terminal_complete "$session_key" "$work_dir" "$issue_number" "$repo_slug" "$issue_json"; then
		_hrw_pr_less_normalize_labels "$issue_number" "$repo_slug" "$issue_json" || return 1
		# Scoped evidence is freshly regenerated, never replayed from this cache.
		if [[ -z "$_HRW_SCOPED_DELIVERY_RECEIPT" && -z "$_HRW_REVIEW_TRIAGE_VERIFIED" ]]; then
			_HRW_PR_LESS_VERIFIED_CONTEXT="$context"
		fi
		_HRW_PR_LESS_REJECTION=""
		return 0
	fi
	# An opted-in contract's own reason outranks later fallbacks' generic misses
	# (for example already_satisfied_receipt_missing), which hid malformed receipts.
	if [[ -n "${_HRW_PR_LESS_OPTED_REJECTION:-}" ]]; then
		_HRW_PR_LESS_REJECTION="$_HRW_PR_LESS_OPTED_REJECTION"
	fi
	return 1
}

# Reconcile only the verified closed task, preserving unrelated labels. Do not
# cache success until this write succeeds, so a transient failure is retryable.
_hrw_pr_less_normalize_labels() {
	local issue_number="$1" repo_slug="$2" issue_json="$3"
	local label=""
	local -a args=(--add-label "status:done")
	while IFS= read -r label; do
		[[ -n "$label" ]] && args+=(--remove-label "$label")
	done < <(jq -r '.labels[]?.name | select(. == "auto-dispatch" or (startswith("status:") and . != "status:done"))' <<<"$issue_json")
	_HRW_PR_LESS_REJECTION="completion_labels_unavailable"
	gh issue edit "$issue_number" --repo "$repo_slug" "${args[@]}" >/dev/null 2>&1 || return 1
	return 0
}

# A trusted triager's semantic disposition is not implementation delivery. Bind
# its structured receipt to this attempt, authenticated closer and original
# inline review, then independently verify the cited merged file on live default.
# No labels, final prose or historical receipts establish this outcome.
_hrw_review_triage_terminal_complete() {
	local session_key="$1" work_dir="$2" issue_number="$3" repo_slug="$4" issue_json="$5"
	local source_pr path comments receipt actor review evidence_pr pr_json files blob review_id default_blob
	local comments_endpoint issue_url="https://github.com/${repo_slug}/issues/${issue_number}"
	printf -v comments_endpoint 'repos/%s/issues/%s/comments?per_page=100' "$repo_slug" "$issue_number"
	local writer_def='def writer: .author_association | strings | test("^(OWNER|MEMBER|COLLABORATOR)$");'
	# Non-generated implementation issues retain their original rejection reason.
	jq -e "${writer_def}"'
		writer and ((.body // "")
		| startswith("## Unactioned Review Feedback\n")
		and contains("quality-feedback-helper.sh scan-merged"))' \
		<<<"$issue_json" >/dev/null 2>&1 || return 1
	_HRW_REVIEW_TRIAGE_CANDIDATE=1
	_HRW_PR_LESS_REJECTION="triage_context_invalid"
	[[ "${DISPATCH_REPO_SLUG:-}" == "$repo_slug" && "${WORKER_ISSUE_NUMBER:-}" == "$issue_number" &&
		-n "${AIDEVOPS_ATTEMPT_ID:-}" && "${AIDEVOPS_ATTEMPT_STARTED_AT:-}" =~ ^[0-9]{19}$ ]] || return 1
	jq -e --argjson issue "$issue_number" --arg url "$issue_url" --arg completed completed '
		.number == $issue and .pull_request == null and .state == "closed"
		and (.state_reason == $completed or .state_reason == "not_planned")
		and .html_url == $url
		and (.body | test("(?m)^\\*\\*Findings\\*\\*: 1$"))
		and ([.body | scan("\\[View comment\\]\\(")] | length) == 1' \
		<<<"$issue_json" >/dev/null 2>&1 || return 1
	source_pr=$(jq -er '.body | capture("(?m)^\\*\\*Source PR\\*\\*: #(?<pr>[1-9][0-9]*)$").pr' <<<"$issue_json") || return 1
	path=$(jq -er '.body | capture("(?m)^\\*\\*File\\*\\*: `(?<path>[^`\\n]+)`$").path
		| select(test("^([A-Za-z0-9_.-]+/)*[A-Za-z0-9_.-]+$") and (split("/") | all(.[]; . != ".." and . != ".")))' \
		<<<"$issue_json") || return 1
	_HRW_PR_LESS_REJECTION="triage_receipt_unavailable"
	actor=$(gh api user --jq '.login' 2>/dev/null) || return 1
	[[ -n "$actor" ]] || return 1
	comments=$(gh api --paginate "$comments_endpoint" 2>/dev/null) || return 1
	_HRW_PR_LESS_REJECTION="triage_receipt_invalid"
	# aidevops:trust-boundary — trust forge metadata, not receipt author claims.
	receipt=$(jq -rse --arg repo "$repo_slug" --argjson issue "$issue_number" --arg actor "$actor" \
		--arg attempt "$AIDEVOPS_ATTEMPT_ID" --arg started "$AIDEVOPS_ATTEMPT_STARTED_AT" \
		--arg url "$issue_url" --arg numeric number --arg text string \
		--argjson source "$source_pr" --arg path "$path" --argjson task "$issue_json" "${writer_def}"'
		def positive_id: type == $numeric and . > 0 and floor == .;
		[.[][]] as $comments
		| select(all($comments[]; ((.body // "")
			| startswith("## Additional Review Feedback (PR #")) | not))
		| [$comments[] | select(writer and .user.login == $actor and $task.closed_by.login == $actor)
		| select((.body // "")
			| startswith("<!-- aidevops:review-triage-completion:v1 -->\n"))
		| . as $comment | (try (.body | split("\n")[1] | fromjson) catch {})
		| select(.schema == 1 and .repository == $repo and .issue == $issue
			and .attempt_id == $attempt and .attempt_started_at == $started
			and (.disposition == "obsolete" or .disposition == "premise_falsified")
			and (.rationale | type == $text and length >= 20)
			and .source_pr == $source and .path == $path
			and (.review_comment_id | positive_id) and (.evidence_pr | positive_id)
			and (.blob | type == $text and test("^[0-9a-f]{40}$"))
			and $comment.html_url == ($url + "#issuecomment-" + ($comment.id | tostring))
			and ($comment.created_at | fromdateiso8601) >= (($started | tonumber) / 1000000000 | floor)
			and ($comment.updated_at | fromdateiso8601) <= ($task.closed_at | fromdateiso8601))]
		| select(length == 1) | .[0]' <<<"$comments" 2>/dev/null) || return 1
	_HRW_PR_LESS_REJECTION="triage_review_invalid"
	review_id=$(jq -r '.review_comment_id' <<<"$receipt")
	review=$(gh api "repos/${repo_slug}/pulls/comments/${review_id}" 2>/dev/null) || return 1
	jq -e --arg repo "$repo_slug" --arg pr "$source_pr" --arg path "$path" --arg id "$review_id" \
		--arg body "$(jq -r '.body' <<<"$issue_json")" '
		.pull_request_url == ("https://api.github.com/repos/" + $repo + "/pulls/" + $pr)
		and .html_url == ("https://github.com/" + $repo + "/pull/" + $pr + "#discussion_r" + $id)
		and .path == $path and (.body | strings | length > 0)
		and (.body as $review | $body | contains($review))
		and (.html_url as $url | $body | contains("[View comment](" + $url + ")"))' \
		<<<"$review" >/dev/null 2>&1 || return 1
	_HRW_PR_LESS_REJECTION="triage_support_invalid"
	evidence_pr=$(jq -r '.evidence_pr' <<<"$receipt")
	pr_json=$(gh api "repos/${repo_slug}/pulls/${evidence_pr}" 2>/dev/null) || return 1
	jq -e --arg repo "$repo_slug" --argjson pr "$evidence_pr" '
		.number == $pr and .state == "closed" and .merged_at != null
		and .base.repo.full_name == $repo' <<<"$pr_json" >/dev/null 2>&1 || return 1
	files=$(gh api --paginate "repos/${repo_slug}/pulls/${evidence_pr}/files?per_page=100" 2>/dev/null) || return 1
	blob=$(jq -r '.blob' <<<"$receipt")
	jq -se --arg path "$path" --arg blob "$blob" \
		'any(.[][]; .filename == $path and .sha == $blob and .status != "removed")' \
		<<<"$files" >/dev/null 2>&1 || return 1
	_hrw_pr_less_worktree_clean "$work_dir" "$repo_slug" || return 1
	_HRW_PR_LESS_REJECTION="triage_default_blob_mismatch"
	default_blob=$(git -C "$work_dir" rev-parse "FETCH_HEAD:${path}" 2>/dev/null) || return 1
	[[ "$default_blob" == "$blob" ]] || return 1
	_HRW_REVIEW_TRIAGE_VERIFIED=1
	print_info "[lifecycle] worker_review_triage complete session=${session_key} issue=${issue_number} implementation=none"
	return 0
}

# A different worker may have delivered the issue before this run. Require an
# exact closing reference or independently verified full-scope delivery on a
# merged PR, and no unpublished work; prose and search matches are not proof.
_hrw_already_delivered_terminal_complete() {
	local session_key="$1"
	local work_dir="$2"
	local issue_number="$3"
	local repo_slug="$4"
	local issue_json="$5"
	_HRW_PR_LESS_REJECTION="issue_not_trusted_completed"
	jq -e '.state == "closed" and .state_reason == "completed"
		and (.author_association == "OWNER" or .author_association == "MEMBER" or .author_association == "COLLABORATOR")' \
		<<<"$issue_json" >/dev/null 2>&1 || return 1
	local candidates="" pr_number="" pr_json="" scoped_rejection=""
	_HRW_PR_LESS_REJECTION="candidate_discovery_unavailable"
	candidates=$(gh pr list --repo "$repo_slug" --state merged --search "$issue_number" \
		--limit 20 --json number --jq '.[].number' 2>/dev/null) || return 1
	_HRW_PR_LESS_REJECTION="no_merged_pr_candidate"
	while IFS= read -r pr_number; do
		[[ "$pr_number" =~ ^[1-9][0-9]*$ ]] || continue
		_HRW_PR_LESS_REJECTION="candidate_evidence_unavailable"
		pr_json=$(gh pr view "$pr_number" --repo "$repo_slug" \
			--json state,mergedAt,closingIssuesReferences 2>/dev/null) || continue
		jq -e --argjson issue "$issue_number" --arg repo "$repo_slug" \
			'.state == "MERGED" and .mergedAt != null
			and any(.closingIssuesReferences[]?; .number == $issue
				and ((.repository.owner.login + "/" + .repository.name) | ascii_downcase) == ($repo | ascii_downcase))' \
			<<<"$pr_json" >/dev/null 2>&1 || {
			_hrw_scoped_delivery_terminal_complete "$work_dir" "$issue_number" "$repo_slug" "$pr_number" "$issue_json" && return 0
			# Do not lose a concrete receipt/local-work rejection when another
			# search candidate later becomes unreadable. Retain one bounded reason.
			[[ -n "$scoped_rejection" ]] || scoped_rejection="$_HRW_PR_LESS_REJECTION"
			continue
		}
		_hrw_pr_less_worktree_clean "$work_dir" "$repo_slug" || return 1
		print_info "[lifecycle] worker_already_delivered complete session=${session_key} issue=${issue_number} pr=${pr_number}"
		return 0
	done <<<"$candidates"
	[[ -z "$scoped_rejection" ]] || _HRW_PR_LESS_REJECTION="$scoped_rejection"
	return 1
}

# GH#37515: a worker may verify an already-satisfied or premise-falsified issue
# and close it without a PR. Credit only a structured receipt bound to this
# attempt, the authenticated closer, an issue-named path at its live-default blob
# and (for already_satisfied) a merged PR touching that path. Issues not closed
# during this attempt keep the prior predicate's rejection reason.
_hrw_already_satisfied_terminal_complete() {
	local session_key="$1" work_dir="$2" issue_number="$3" repo_slug="$4" issue_json="$5"
	local actor comments verdict reason path blob evidence_pr pr_json files default_blob comments_endpoint
	printf -v comments_endpoint 'repos/%s/issues/%s/comments?per_page=100' "$repo_slug" "$issue_number"
	# Review feedback keeps its own receipt and never falls back to this one.
	[[ -z "${_HRW_REVIEW_TRIAGE_CANDIDATE:-}" ]] || return 1
	[[ "${DISPATCH_REPO_SLUG:-}" == "$repo_slug" && "${WORKER_ISSUE_NUMBER:-}" == "$issue_number" &&
		-n "${AIDEVOPS_ATTEMPT_ID:-}" && "${AIDEVOPS_ATTEMPT_STARTED_AT:-}" =~ ^[0-9]{19}$ ]] || return 1
	jq -e --arg started "$AIDEVOPS_ATTEMPT_STARTED_AT" '
		.state == "closed" and .pull_request == null and ((.closed_by.login // "") | length > 0)
		and ((try (.closed_at | fromdateiso8601) catch 0) >= (($started | tonumber) / 1000000000 | floor))' \
		<<<"$issue_json" >/dev/null 2>&1 || return 1
	_HRW_PR_LESS_REJECTION="already_satisfied_receipt_unavailable"
	actor=$(gh api user --jq '.login' 2>/dev/null) || return 1
	[[ -n "$actor" ]] || return 1
	comments=$(gh api --paginate "$comments_endpoint" 2>/dev/null) || return 1
	_HRW_PR_LESS_REJECTION="already_satisfied_receipt_invalid"
	verdict=$(_hrw_already_satisfied_receipt_verdict "$repo_slug" "$issue_number" "$actor" "$issue_json" <<<"$comments") || return 1
	reason=$(jq -r '.reason' <<<"$verdict" 2>/dev/null) || return 1
	if [[ -n "$reason" ]]; then
		# Verdicts are program constants; never copy arbitrary text into metrics.
		[[ "$reason" =~ ^already_satisfied_[a-z_]+$ ]] && _HRW_PR_LESS_REJECTION="$reason"
		return 1
	fi
	path=$(jq -r '.receipt.path' <<<"$verdict") || return 1
	blob=$(jq -r '.receipt.blob' <<<"$verdict") || return 1
	evidence_pr=$(jq -r '.receipt.evidence_pr // empty' <<<"$verdict") || return 1
	if [[ -n "$evidence_pr" ]]; then
		_HRW_PR_LESS_REJECTION="already_satisfied_evidence_unavailable"
		pr_json=$(gh api "repos/${repo_slug}/pulls/${evidence_pr}" 2>/dev/null) || return 1
		files=$(gh api --paginate "repos/${repo_slug}/pulls/${evidence_pr}/files?per_page=100" 2>/dev/null) || return 1
		_HRW_PR_LESS_REJECTION="already_satisfied_evidence_invalid"
		jq -e --arg repo "$repo_slug" --argjson pr "$evidence_pr" '
			.number == $pr and .state == "closed" and .merged_at != null
			and .base.repo.full_name == $repo' <<<"$pr_json" >/dev/null 2>&1 || return 1
		jq -se --arg path "$path" 'any(.[][]; .filename == $path and .status != "removed")' \
			<<<"$files" >/dev/null 2>&1 || return 1
	fi
	_hrw_pr_less_worktree_clean "$work_dir" "$repo_slug" || return 1
	# The clean guard fetched the exact live default tip into FETCH_HEAD.
	_HRW_PR_LESS_REJECTION="already_satisfied_default_blob_mismatch"
	default_blob=$(git -C "$work_dir" rev-parse "FETCH_HEAD:${path}" 2>/dev/null) || return 1
	[[ "$default_blob" == "$blob" ]] || return 1
	print_info "[lifecycle] worker_already_satisfied complete session=${session_key} issue=${issue_number} attempt=${AIDEVOPS_ATTEMPT_ID} implementation=none"
	return 0
}

# Classify paginated issue comments (stdin) into one constant rejection reason,
# or an empty reason plus the single fresh receipt authored by the closer.
# aidevops:trust-boundary — trust forge metadata, not receipt author claims.
# Args: repo_slug issue_number actor issue_json
_hrw_already_satisfied_receipt_verdict() {
	local repo_slug="$1" issue_number="$2" actor="$3" issue_json="$4"
	jq -cse --arg repo "$repo_slug" --argjson issue "$issue_number" --arg actor "$actor" \
		--arg attempt "$AIDEVOPS_ATTEMPT_ID" --arg started "$AIDEVOPS_ATTEMPT_STARTED_AT" \
		--arg url "https://github.com/${repo_slug}/issues/${issue_number}" \
		--arg marker '<!-- aidevops:already-satisfied-completion:v1 -->' --argjson task "$issue_json" \
		--arg numeric number --arg text string --arg sha '^[0-9a-f]{40}$' '
		def writer: (.author_association // "none") | test("^(OWNER|MEMBER|COLLABORATOR)$");
		def secs: try fromdateiso8601 catch null;
		def positive_id: type == $numeric and . > 0 and floor == .;
		def safe_path: type == $text and test("^([A-Za-z0-9_.-]+/)*[A-Za-z0-9_.-]+$")
			and (split("/") | all(.[]; . != ".." and . != "."));
		# Compare whole path tokens; allow a single sentence-ending period,
		# but never a parent directory, extension, or dotted path continuation.
		def names_path($path): any(scan("[A-Za-z0-9_./-]+"); . == $path or . == ($path + "."));
		def valid_receipt: type == "object" and .schema == 1 and .repository == $repo and .issue == $issue
			and .attempt_id == $attempt and .attempt_started_at == $started
			and (.disposition == "already_satisfied" or .disposition == "premise_falsified")
			and (.rationale | type == $text and length >= 20)
			and (.path | safe_path) and (.blob | type == $text and test($sha))
			and (if .disposition == "already_satisfied" then (.evidence_pr | positive_id)
				else (.evidence_pr == null or (.evidence_pr | positive_id)) end);
		def verdict($reason): {reason: $reason};
		(($started | tonumber) / 1000000000 | floor) as $start
		| ($task.closed_at | secs) as $closed
		| [.[][] | select((.body // "") | startswith($marker + "\n"))] as $marked
		| [$marked[] | select(.user.login == $actor)] as $own
		| [$own[] | select((.created_at | secs) as $t | ($t != null and $t >= $start))] as $fresh
		| if ($marked | length) == 0 then verdict("already_satisfied_receipt_missing")
		elif ($own | length) == 0 then verdict("already_satisfied_closer_mismatch")
		elif ($fresh | length) == 0 then verdict("already_satisfied_receipt_stale")
		elif ($fresh | length) > 1 then verdict("already_satisfied_receipt_duplicated")
		else $fresh[0] as $c
			| (try ($c.body | split("\n")[1] | fromjson) catch null) as $r
			| if ($task.closed_by.login // "") != $actor or ($c | writer | not) then
				verdict("already_satisfied_closer_mismatch")
			elif $closed == null or ((($c.updated_at | secs) // 1e300) > $closed) then
				verdict("already_satisfied_receipt_edited")
			elif ($c.id | positive_id | not) or $c.html_url != "\($url)#issuecomment-\($c.id)"
				or ($r | valid_receipt | not) then verdict("already_satisfied_receipt_invalid")
			elif (($task.body // "") | names_path($r.path) | not) then verdict("already_satisfied_path_unbound")
			else {reason: "", receipt: $r} end
		end' 2>/dev/null || return 1
	return 0
}

# A fresh verifier-produced lifecycle receipt is an alternative only for a
# completed, fully delivered literal scope. It cannot close an issue, authorize
# publication, or bypass the unchanged no-unpublished-work guard.
_hrw_scoped_delivery_terminal_complete() {
	local work_dir="$1" issue_number="$2" repo_slug="$3" pr_number="$4" issue_json="$5"
	local receipt head branch path blob
	_HRW_PR_LESS_REJECTION="scoped_attempt_binding_missing"
	[[ -n "${AIDEVOPS_ATTEMPT_ID:-}" && "${AIDEVOPS_ATTEMPT_STARTED_AT:-}" =~ ^[0-9]{19}$ ]] || return 1
	_hrw_pr_less_worktree_clean "$work_dir" "$repo_slug" || return 1
	_HRW_PR_LESS_REJECTION="scoped_local_context_unavailable"
	work_dir=$(cd "$work_dir" && pwd -P) || return 1
	head=$(git -C "$work_dir" rev-parse HEAD) || return 1
	branch=$(git -C "$work_dir" branch --show-current) || return 1
	_HRW_PR_LESS_REJECTION="scoped_receipt_unavailable"
	receipt=$(bash "${SCRIPT_DIR}/verify-issue-close-helper.sh" check-scoped-delivery \
		"$issue_number" "$pr_number" "$repo_slug" "$work_dir" 2>/dev/null) || return 1
	_HRW_PR_LESS_REJECTION="scoped_receipt_invalid"
	jq -e --arg repo "$repo_slug" --argjson issue "$issue_number" --argjson pr "$pr_number" \
		--arg attempt "$AIDEVOPS_ATTEMPT_ID" --arg started "$AIDEVOPS_ATTEMPT_STARTED_AT" \
		--arg worktree "$work_dir" --arg head "$head" --arg branch "$branch" \
		--arg updated "$(jq -r '.updated_at' <<<"$issue_json")" '
		.schema_version == 1 and .kind == "scoped_delivery" and .verified == true
		and .repository == $repo and .issue == $issue and .pr == $pr
		and .attempt_id == $attempt and .attempt_started_at == $started
		and .worktree == $worktree and .head == $head and .branch == $branch
		and .issue_updated_at == $updated and (.files | length > 0)
	' <<<"$receipt" >/dev/null 2>&1 || return 1
	# The guard fetched the exact live default tip. A behind checkout must not
	# hide artifacts subsequently removed or reverted on that integration branch.
	_HRW_PR_LESS_REJECTION="scoped_default_blob_mismatch"
	while IFS=$'\t' read -r path blob; do
		[[ "$(git -C "$work_dir" rev-parse "FETCH_HEAD:${path}" 2>/dev/null)" == "$blob" ]] || return 1
	done < <(jq -r '.files[] | [.path,.blob] | @tsv' <<<"$receipt")
	_HRW_SCOPED_DELIVERY_RECEIPT="$receipt"
	print_info "[lifecycle] worker_scoped_delivery complete issue=${issue_number} pr=${pr_number} attempt=${AIDEVOPS_ATTEMPT_ID} head=${head}"
	return 0
}

# A PR-less completion must leave nothing unpublished: a clean non-default
# branch at or behind the live default tip, no pushed orphan and no PR.
_hrw_pr_less_worktree_clean() {
	local work_dir="$1"
	local repo_slug="$2"
	local default_branch="" default_ref="" branch="" remote_tip="" local_head="" pr_count="" task_status=""
	_HRW_PR_LESS_REJECTION="default_branch_unavailable"
	default_branch=$(_hrw_resolve_default_branch "$work_dir") || return 1
	[[ -n "$default_branch" ]] || return 1
	_HRW_PR_LESS_REJECTION="worktree_branch_invalid"
	branch=$(git -C "$work_dir" branch --show-current 2>/dev/null) || return 1
	[[ -n "$branch" && "$branch" != "$default_branch" ]] || return 1
	_HRW_PR_LESS_REJECTION="worktree_status_unavailable"
	task_status=$(_hrw_task_worktree_status "$work_dir") || return 1
	_HRW_PR_LESS_REJECTION="unpublished_worktree_changes"
	[[ -z "$task_status" ]] || return 1
	_HRW_PR_LESS_REJECTION="local_head_unavailable"
	local_head=$(git -C "$work_dir" rev-parse HEAD 2>/dev/null) || return 1
	default_ref="refs/heads/${default_branch}"
	_HRW_PR_LESS_REJECTION="default_tip_unavailable"
	remote_tip=$(git -C "$work_dir" ls-remote origin "$default_ref" 2>/dev/null) || return 1
	remote_tip="${remote_tip%%[[:space:]]*}"
	[[ "$remote_tip" =~ ^[0-9a-f]{40}$ ]] || return 1
	# Do not trust a stale origin/default tracking ref; fetch the exact live tip.
	git -C "$work_dir" fetch -q origin "$default_ref" 2>/dev/null || return 1
	_HRW_PR_LESS_REJECTION="default_tip_changed"
	[[ "$(git -C "$work_dir" rev-parse FETCH_HEAD 2>/dev/null)" == "$remote_tip" ]] || return 1
	_HRW_PR_LESS_REJECTION="unpublished_local_commits"
	[[ "$(git -C "$work_dir" rev-list --count "${remote_tip}..${local_head}" 2>/dev/null)" == "0" ]] || return 1
	# A pushed orphan (even if the local branch is clean) must never be waived.
	local remote_branch=""
	_HRW_PR_LESS_REJECTION="remote_branch_unavailable"
	remote_branch=$(git -C "$work_dir" ls-remote origin "refs/heads/${branch}" 2>/dev/null) || return 1
	_HRW_PR_LESS_REJECTION="unpublished_remote_branch"
	[[ -z "$remote_branch" || "${remote_branch%%[[:space:]]*}" == "$local_head" ]] || return 1
	_HRW_PR_LESS_REJECTION="branch_pr_evidence_unavailable"
	pr_count=$(gh pr list --repo "$repo_slug" --head "$branch" --state all --json number --jq 'length' 2>/dev/null) || return 1
	_HRW_PR_LESS_REJECTION="branch_has_pr"
	[[ "$pr_count" == "0" ]] || return 1
	return 0
}

# True when any comment starts with the receipt marker line. Separates a
# missing receipt from a malformed one in rejection reasons (GH#40048).
# Args: comments_json receipt_marker
_hrw_pr_less_receipt_present() {
	local comments_json="$1" receipt_marker="$2"
	local prefix=""
	printf -v prefix '%s\n' "$receipt_marker"
	jq -se --arg prefix "$prefix" 'any(.[][]; (.body // "") | startswith($prefix))' \
		<<<"$comments_json" >/dev/null 2>&1 || return 1
	return 0
}

# A PR-less terminal state is valid only for an explicitly authorized data-only
# objective with a trusted, issue-bound publication receipt. This is evidence
# classification, never authority to perform the publication itself.
# Args: session_key work_dir issue_number repo_slug [prefetched issue JSON]
_hrw_data_only_terminal_complete() {
	local session_key="$1"
	local work_dir="$2"
	local issue_number="$3"
	local repo_slug="$4"
	local issue_json="${5:-}"
	[[ "$issue_number" =~ ^[1-9][0-9]*$ && "$repo_slug" == */* ]] || return 1
	[[ "${WORKER_ISSUE_NUMBER:-$issue_number}" == "$issue_number" ]] || return 1
	[[ -d "$work_dir" ]] || return 1
	local comments=""
	if [[ -z "$issue_json" ]]; then
		issue_json=$(gh api "repos/${repo_slug}/issues/${issue_number}" 2>/dev/null) || return 1
	fi
	jq -e --arg marker '<!-- aidevops:completion-contract:data-only/v1 -->' \
		'(.body // "") | contains($marker)' <<<"$issue_json" >/dev/null 2>&1 || return 1
	# Opted in: record constant reasons later fallbacks cannot mask (GH#40048).
	_HRW_PR_LESS_OPTED_REJECTION="data_only_issue_untrusted"
	jq -e '.state == "closed" and (.author_association == "OWNER" or .author_association == "MEMBER")' \
		<<<"$issue_json" >/dev/null 2>&1 || return 1
	_HRW_PR_LESS_OPTED_REJECTION="data_only_receipt_unavailable"
	comments=$(gh api --paginate "repos/${repo_slug}/issues/${issue_number}/comments?per_page=100" 2>/dev/null) || return 1
	_HRW_PR_LESS_OPTED_REJECTION="data_only_receipt_missing"
	_hrw_pr_less_receipt_present "$comments" '<!-- aidevops:data-only-completion:v1 -->' || return 1
	_HRW_PR_LESS_OPTED_REJECTION="data_only_receipt_invalid"
	jq -se --arg repo "$repo_slug" --argjson issue "$issue_number" '
		any(.[][];
			(.author_association == "OWNER" or .author_association == "MEMBER")
			and ((.body // "") | startswith("<!-- aidevops:data-only-completion:v1 -->\n"))
			and ((.body | split("\n") | .[1]) as $receipt
				| (try ($receipt | fromjson) catch {}) as $r
				| $r.repository == $repo and $r.issue == $issue and $r.status == "published" and $r.verified == true
				and ($r.evidence_url | type == "string" and test("^https://[^/[:space:]]+/[^[:space:]]+$"))))
	' <<<"$comments" >/dev/null 2>&1 || return 1
	if ! _hrw_pr_less_worktree_clean "$work_dir" "$repo_slug"; then
		_HRW_PR_LESS_OPTED_REJECTION="$_HRW_PR_LESS_REJECTION"
		return 1
	fi
	_HRW_PR_LESS_OPTED_REJECTION=""
	print_info "[lifecycle] worker_data_only_terminal complete session=${session_key} issue=${issue_number}"
	return 0
}

# Reports are not publications. Bind the receipt to its own GitHub comment URL
# and prove the closer's association using trusted comment metadata.
_hrw_report_only_terminal_complete() {
	local session_key="$1" work_dir="$2" issue_number="$3" repo_slug="$4" issue_json="$5"
	local comments=""
	local comments_endpoint=""
	printf -v comments_endpoint 'repos/%s/issues/%s/comments?per_page=100' "$repo_slug" "$issue_number"
	local trusted_def='def trusted: (.author_association // "") | test("^(OWNER|MEMBER)$");'
	jq -e --arg marker '<!-- aidevops:completion-contract:report-only/v1 -->' \
		'(.body // "") | contains($marker)' <<<"$issue_json" >/dev/null 2>&1 || return 1
	# Opted in: record constant reasons later fallbacks cannot mask (GH#40048).
	_HRW_PR_LESS_OPTED_REJECTION="report_only_issue_invalid"
	# aidevops:trust-boundary — only scanner alerts may trust a COLLABORATOR,
	# bound to the same issue author, closer and receipt author login.
	local peer_login=""
	local peer_def="def collaborator: .author_association == \$peer_association;"
	local peer_association='COLLABORATOR'
	peer_login=$(jq -r --arg peer_association "$peer_association" "${peer_def}"'
		select(collaborator
			and ((.title // "") |
				startswith("GH Audit Anomaly Alert:") or startswith("GH Audit Log Integrity Alert:"))
			and ((.body // "") | contains("<!-- gh-audit-anomaly-scanner:"))
			and any(.labels[]?; .name == "monitoring"))
		| .user.login // empty' <<<"$issue_json") || return 1
	jq -e --arg closed closed --arg completed completed --arg peer "$peer_login" "${trusted_def}"'
		def scanner_peer: $peer != "" and .user.login == $peer and .closed_by.login == $peer;
		.state == $closed and .state_reason == $completed and (trusted or scanner_peer)
		and ((.body // "") | contains("<!-- aidevops:completion-contract:report-only/v1 -->"))' \
		<<<"$issue_json" >/dev/null 2>&1 || return 1
	_HRW_PR_LESS_OPTED_REJECTION="report_only_receipt_unavailable"
	comments=$(gh api --paginate "$comments_endpoint" 2>/dev/null) || return 1
	_HRW_PR_LESS_OPTED_REJECTION="report_only_receipt_missing"
	_hrw_pr_less_receipt_present "$comments" '<!-- aidevops:report-only-completion:v1 -->' || return 1
	_HRW_PR_LESS_OPTED_REJECTION="report_only_receipt_invalid"
	jq -se --arg repo "$repo_slug" --argjson issue "$issue_number" --arg peer "$peer_login" \
		--arg peer_association "$peer_association" \
		--arg closer "$(jq -r '.closed_by.login // ""' <<<"$issue_json")" "${trusted_def}${peer_def}"'
		def report_writer:
			if $peer == "" then trusted
			else .user.login == $peer and (trusted or collaborator) end;
		[.[][]] as $comments
		| ($closer != "" and any($comments[]; report_writer and .user.login == $closer))
		and any($comments[]; report_writer
			and ((.body // "") | startswith("<!-- aidevops:report-only-completion:v1 -->\n"))
			and (.html_url as $url | .id as $id
				| (try (.body | split("\n")[1] | fromjson) catch {}) as $r
				| $r.repository == $repo and $r.issue == $issue
				and $r.status == "reported" and $r.verified == true
				and ($id | type == "number" and . > 0)
				and $url == ("https://github.com/" + $repo + "/issues/" + ($issue | tostring) + "#issuecomment-" + ($id | tostring))
				and $r.evidence_url == $url))
	' <<<"$comments" >/dev/null 2>&1 || return 1
	if ! _hrw_pr_less_worktree_clean "$work_dir" "$repo_slug"; then
		_HRW_PR_LESS_OPTED_REJECTION="$_HRW_PR_LESS_REJECTION"
		return 1
	fi
	_HRW_PR_LESS_OPTED_REJECTION=""
	print_info "[lifecycle] worker_report_only_terminal complete session=${session_key} issue=${issue_number}"
	return 0
}

# Consolidation children (pulse-triage-dispatch.sh) are operational tasks whose
# completion is a successor issue, a closed parent and a self-close, never a PR.
# Every link is cross-checked against trusted GitHub state; this classifies
# evidence only and grants no authority to write (GH#32984). Peer pulse runners
# with write access author these artifacts as COLLABORATOR, so write-access
# associations are trusted here (the data-only opt-in stays OWNER/MEMBER).
# Args: session_key work_dir issue_number repo_slug [prefetched issue JSON]
_hrw_consolidation_terminal_complete() {
	local session_key="$1"
	local work_dir="$2"
	local issue_number="$3"
	local repo_slug="$4"
	local issue_json="${5:-}"
	[[ "$issue_number" =~ ^[1-9][0-9]*$ && "$repo_slug" == */* ]] || return 1
	[[ "${WORKER_ISSUE_NUMBER:-$issue_number}" == "$issue_number" ]] || return 1
	[[ -d "$work_dir" ]] || return 1
	local comments="" parent_num="" successor_num="" parent_json="" successor_json=""
	local writer_def='def writer: .author_association == "OWNER" or .author_association == "MEMBER" or .author_association == "COLLABORATOR";'
	if [[ -z "$issue_json" ]]; then
		issue_json=$(gh api "repos/${repo_slug}/issues/${issue_number}" 2>/dev/null) || return 1
	fi
	parent_num=$(jq -r "${writer_def}"'
		select(.state == "closed" and .state_reason == "completed" and writer
			and any(.labels[]?; .name == "consolidation-task"))
		| [(.body // "") | split("\n")[]
			| capture("^## Consolidation target: #(?<n>[1-9][0-9]*)\\s*$") | .n] | first // empty
	' <<<"$issue_json" 2>/dev/null) || return 1
	[[ "$parent_num" =~ ^[1-9][0-9]*$ && "$parent_num" != "$issue_number" ]] || return 1
	comments=$(gh api --paginate "repos/${repo_slug}/issues/${issue_number}/comments?per_page=100" 2>/dev/null) || return 1
	successor_num=$(jq -rs --arg parent "$parent_num" "${writer_def}"'
		[.[][] | select(writer)
			| (.body // "")
			| capture("^Consolidation complete\\. Parent: #(?<p>[1-9][0-9]*) (?:→|->) New: #(?<n>[1-9][0-9]*)")
			| select(.p == $parent) | .n] | last // empty
	' <<<"$comments" 2>/dev/null) || return 1
	[[ "$successor_num" =~ ^[1-9][0-9]*$ && "$successor_num" != "$issue_number" && "$successor_num" != "$parent_num" ]] || return 1
	parent_json=$(gh api "repos/${repo_slug}/issues/${parent_num}" 2>/dev/null) || return 1
	jq -e '.state == "closed" and any(.labels[]?; .name == "consolidated")' \
		<<<"$parent_json" >/dev/null 2>&1 || return 1
	successor_json=$(gh api "repos/${repo_slug}/issues/${successor_num}" 2>/dev/null) || return 1
	# The successor's own lifecycle may later drop its `consolidated` label, so
	# bind it by author and the template's `Supersedes #P` line instead.
	jq -e --arg parent "$parent_num" "${writer_def}"'
		(.pull_request | not) and writer
		and ((.body // "") | test("Supersedes #" + $parent + "([^0-9]|$)"))
	' <<<"$successor_json" >/dev/null 2>&1 || return 1
	_hrw_pr_less_worktree_clean "$work_dir" "$repo_slug" || return 1
	print_info "[lifecycle] worker_consolidation_terminal complete session=${session_key} issue=${issue_number} parent=#${parent_num} successor=#${successor_num}"
	return 0
}

#######################################
# Prove that a permission request happened after this exact worker objective
# merged and transferred cleanup ownership to the guarded supervisor.
#
# Args: $1=session_key, $2=runtime session ID, $3=worker worktree
# Stdout: PR number, receipt path, cleanup state, executor state, owner session
# Returns: 0 only for exact merged/closed/receipt evidence; otherwise 1
#######################################
_hrw_post_merge_permission_completion_evidence() {
	local session_key="$1"
	local runtime_session="$2"
	local work_dir="$3"
	local repo_slug="${DISPATCH_REPO_SLUG:-${WORKER_REPO_SLUG:-}}"
	local issue_number=""

	[[ "$session_key" == issue-* && -n "$runtime_session" && -n "$repo_slug" ]] || return 1
	[[ -n "$work_dir" && -d "$work_dir" ]] || return 1
	if [[ "$session_key" =~ ([0-9]+)$ ]]; then
		issue_number="${BASH_REMATCH[1]}"
	fi
	[[ "$issue_number" =~ ^[1-9][0-9]*$ ]] || return 1
	if [[ -n "${WORKER_ISSUE_NUMBER:-}" && "${WORKER_ISSUE_NUMBER}" != "$issue_number" ]]; then
		return 1
	fi

	local issue_state=""
	issue_state=$(gh issue view "$issue_number" --repo "$repo_slug" --json state --jq '.state // empty' 2>/dev/null || true)
	[[ "$issue_state" == "CLOSED" ]] || return 1

	local resolved_worktree=""
	local branch_name=""
	local local_head=""
	resolved_worktree=$(cd "$work_dir" 2>/dev/null && pwd -P) || return 1
	branch_name=$(git -C "$resolved_worktree" branch --show-current 2>/dev/null || true)
	local_head=$(git -C "$resolved_worktree" rev-parse HEAD 2>/dev/null || true)
	[[ -n "$branch_name" && -n "$local_head" ]] || return 1

	local handoff_state=""
	local pr_number=""
	handoff_state=$(_pr_handoff_state_for_branch_or_issue "$branch_name" "$issue_number" \
		"$repo_slug" "head-only" "$local_head" 1)
	[[ "${handoff_state%%|*}" == "merged" ]] || return 1
	pr_number="${handoff_state#*|}"
	[[ "$pr_number" =~ ^[1-9][0-9]*$ ]] || return 1
	_full_loop_read_fresh_merged_pr_json "$pr_number" "$repo_slug" >/dev/null || return 1

	local receipt_path=""
	receipt_path=$(_full_loop_cleanup_receipt_path "$repo_slug" "$pr_number") || return 1
	[[ -f "$receipt_path" ]] || return 1
	local receipt_fields=""
	receipt_fields=$(jq -er \
		--arg repo "$repo_slug" --argjson pr "$pr_number" \
		--arg worktree "$resolved_worktree" --arg branch "$branch_name" \
		--arg session "$runtime_session" \
		--arg deferred "$_FULL_LOOP_CLEANUP_DEFERRED" \
		--arg leased "$_FULL_LOOP_CLEANUP_LEASED" '
		select(
			.schema_version == 1
			and .repository == $repo and .pr_number == $pr
			and .worktree == $worktree and .branch == $branch
			and .owner.session == $session
			and (.executor_completion_state == "FINALIZATION_PENDING" or .executor_completion_state == "COMPLETE")
			and (.resource_cleanup_state == $deferred or .resource_cleanup_state == $leased)
		)
		| [.resource_cleanup_state, .executor_completion_state, .owner.session] | @tsv
	' "$receipt_path" 2>/dev/null) || return 1

	printf '%s\t%s\t%s\n' "$pr_number" "$receipt_path" "$receipt_fields"
	return 0
}
