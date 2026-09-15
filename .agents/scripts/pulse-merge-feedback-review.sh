#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Review feedback routing helpers.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

[[ -n "${_PULSE_MERGE_FEEDBACK_REVIEW_LOADED:-}" ]] && return 0
_PULSE_MERGE_FEEDBACK_REVIEW_LOADED=1

#######################################
# Build the markdown "Review Feedback" section for routing to a linked
# issue (t2093).
#
# Reads already-fetched review + inline-comment JSON arrays and produces a
# human-readable section with file:line citations. The section is scoped
# to a single closing PR so the marker in `_dispatch_pr_fix_worker` can
# prevent duplicate appends if the merge pass re-encounters the same PR
# before the close propagates.
#
# Args:
#   $1 - pr_number
#   $2 - repo_slug
#   $3 - reviews_json    (JSON array of {author,state,body,url})
#   $4 - inline_json     (JSON array of {author,path,line,body,url})
#
# Output: markdown section on stdout (empty string if no content).
#######################################
_build_review_feedback_section() {
	local pr_number="$1"
	local repo_slug="$2"
	local reviews_json="${3:-[]}"
	local inline_json="${4:-[]}"

	local reviews_count="" inline_count=""
	reviews_count=$(printf '%s' "$reviews_json" | jq 'length' 2>/dev/null) || reviews_count=0
	inline_count=$(printf '%s' "$inline_json" | jq 'length' 2>/dev/null) || inline_count=0
	[[ "$reviews_count" =~ ^[0-9]+$ ]] || reviews_count=0
	[[ "$inline_count" =~ ^[0-9]+$ ]] || inline_count=0

	if [[ "$reviews_count" -eq 0 && "$inline_count" -eq 0 ]]; then
		return 0
	fi

	local header
	header="## Review Feedback routed from PR #${pr_number} (t2093)

This section was auto-generated when the deterministic merge pass detected
\`reviewDecision=CHANGES_REQUESTED\` on the linked worker PR. A head-bound
finalizer is routing the issue for redispatch. The next worker should address
the findings below and open a fresh PR against this issue.

See the original PR for full context: https://github.com/${repo_slug}/pull/${pr_number}
"

	local reviews_md=""
	if [[ "$reviews_count" -gt 0 ]]; then
		reviews_md=$(printf '%s' "$reviews_json" | jq -r \
			--argjson item_limit "$PULSE_REVIEW_FEEDBACK_ITEM_LIMIT" '
			def quoted_body:
				((.body // "") | gsub("\r"; "") | .[0:$item_limit]) as $body
				| if $body == "" then "  > _(no review body provided)_"
				  else ($body | split("\n") | map("  > " + .) | join("\n")) end;
			.[] | "- **@\(.author)** (`\(.state)`)\n\(quoted_body)\n  [view review](\(.url // ""))"
		' 2>/dev/null) || reviews_md=""
	fi

	local inline_md=""
	if [[ "$inline_count" -gt 0 ]]; then
		inline_md=$(printf '%s' "$inline_json" | jq -r \
			--argjson item_limit "$PULSE_REVIEW_FEEDBACK_ITEM_LIMIT" '
			def quoted_body:
				((.body // "") | gsub("\r"; "") | .[0:$item_limit]) as $body
				| if $body == "" then "  > _(no inline comment body provided)_"
				  else ($body | split("\n") | map("  > " + .) | join("\n")) end;
			.[] | "- **@\(.author)** `\(.path)`:\(.line // "?")\n\(quoted_body)\n  [view comment](\(.url // ""))"
		' 2>/dev/null) || inline_md=""
	fi

	local section="$header"
	if [[ -n "$reviews_md" ]]; then
		section="${section}
### Top-level reviews

${reviews_md}
"
	fi
	if [[ -n "$inline_md" ]]; then
		section="${section}
### Inline comments (file:line citations)

${inline_md}
"
	fi
	printf '%s' "$section" | jq -Rs -r \
		--argjson section_limit "$PULSE_REVIEW_FEEDBACK_SECTION_LIMIT" '
		if length > $section_limit then
			.[0:$section_limit] + "\n\n_[Additional review feedback omitted by the bounded router; use the source links above for full context.]_\n"
		else . end
	' 2>/dev/null || return 1
	return 0
}

#######################################
# Verify that the current review generation contains a substantive top-level
# CHANGES_REQUESTED body from a trusted human reviewer.
#
# This is the fail-closed bridge between a converged no-thread remediation scan
# and the destructive t2093 route. The aggregate reviewDecision alone is not
# enough: bot or untrusted reviews must not authorize closing a worker PR and
# rewriting its linked issue.
#
# Args: $1=pr_number, $2=repo_slug
# Returns: 0 when eligible trusted body feedback exists, 1 otherwise.
#######################################
_review_feedback_has_trusted_body_change_request() {
	local pr_number="$1"
	local repo_slug="$2"
	local reviews_pages=""
	local reviews_json=""
	local changes_requested="${PULSE_REVIEW_DECISION_CHANGES_REQUESTED:-CHANGES_REQUESTED}"
	local json_string_type="string"

	if ! reviews_pages=$(_pmf_gh_read gh api \
		"repos/${repo_slug}/pulls/${pr_number}/reviews?per_page=100" --paginate 2>/dev/null); then
		echo "[pulse-wrapper] review feedback: trusted body-only review evidence unavailable for PR #${pr_number} in ${repo_slug}; preserving CHANGES_REQUESTED" >>"$LOGFILE"
		return 1
	fi
	reviews_json=$(printf '%s\n' "$reviews_pages" | jq -cse '
		if all(.[]; type == "array") then [ .[][] ]
		else error("review evidence page must be an array") end
	') || {
		echo "[pulse-wrapper] review feedback: malformed body-only review evidence for PR #${pr_number} in ${repo_slug}; preserving CHANGES_REQUESTED" >>"$LOGFILE"
		return 1
	}

	printf '%s\n' "$reviews_json" | jq -e \
		--arg changes_requested "$changes_requested" \
		--arg json_string_type "$json_string_type" '
		def state_changing:
			.state == "APPROVED" or .state == $changes_requested or .state == "DISMISSED";
		if any(.[]?; state_changing and (
			(.id | type) != "number"
			or (.submitted_at | type) != $json_string_type
			or (.submitted_at | length) == 0
			or (.user | type) != "object"
			or (.user.login | type) != $json_string_type
			or (.user.login | length) == 0
			or (.user.type | type) != $json_string_type
			or (.author_association | type) != $json_string_type
			or (.body | type) != $json_string_type
		)) then false
		else
			map(select(state_changing))
			| group_by(.user.login)
			| map(max_by([.submitted_at, .id]))
			| any(.[];
				.state == $changes_requested
				and .user.type == "User"
				and (.author_association == "OWNER"
					or .author_association == "MEMBER"
					or .author_association == "COLLABORATOR")
				and ((.body | gsub("\\s"; "")) | length) > 0
			)
		end
	' >/dev/null 2>&1 || return 1
	return 0
}

_review_feedback_ready_reviewer_evidence() {
	local pr_number="$1"
	local repo_slug="$2"
	local reviews_pages=""
	local changes_requested="${PULSE_REVIEW_DECISION_CHANGES_REQUESTED:-CHANGES_REQUESTED}"

	reviews_pages=$(_pmf_gh_read gh api \
		"repos/${repo_slug}/pulls/${pr_number}/reviews?per_page=100" --paginate 2>/dev/null) || return 1
	#aidevops:trust-boundary — only a trusted human's latest substantive change request can preserve a worker PR.
	printf '%s\n' "$reviews_pages" | jq -cse \
		--arg string_type "$PULSE_FEEDBACK_JSON_STRING_TYPE" \
		--arg changes_requested "$changes_requested" '
		if all(.[]; type == ([] | type)) then [ .[][] ]
		else error("review evidence page must be an array") end
		| map(select(.state == "APPROVED" or .state == $changes_requested or .state == "DISMISSED"))
		| if any(.[];
			(.id | type) != "number"
			or (.submitted_at | type) != $string_type or (.submitted_at | length) == 0
			or (.user | type) != "object"
			or (.user.login | type) != $string_type or (.user.login | length) == 0
			or (.user.type | type) != $string_type
			or (.author_association | type) != $string_type
			or (.body | type) != $string_type
			or (.commit_id | type) != $string_type)
		then error("malformed state-changing review evidence")
		else . end
		| group_by(.user.login)
		| map(max_by([.submitted_at, .id]))
		| map(select(
			.state == $changes_requested
			and .user.type == "User"
			and (.author_association == "OWNER" or .author_association == "MEMBER" or .author_association == "COLLABORATOR")
			and ((.body | gsub("\\s"; "")) | length) > 0))
		| if any(.[]; (.commit_id | test("^[0-9a-fA-F]{40}$")) == false)
		then error("trusted change request has invalid head identity")
		else {reviewers: (map(.user.login) | unique), reviewed_heads: (map(.commit_id) | unique)} end
	' 2>/dev/null
	return $?
}

_review_feedback_head_advances_reviews() {
	local repo_slug="$1"
	local current_head="$2"
	local reviewed_heads_json="$3"
	local reviewed_head=""
	local compare_status=""
	local count=0

	count=$(printf '%s' "$reviewed_heads_json" | jq 'length' 2>/dev/null) || return 75
	[[ "$count" =~ ^[1-9][0-9]*$ ]] || return 1
	while IFS= read -r reviewed_head; do
		[[ "$reviewed_head" =~ ^[0-9a-fA-F]{40}$ && "$reviewed_head" != "$current_head" ]] || return 1
		compare_status=$(_pmf_gh_read gh api \
			"repos/${repo_slug}/compare/${reviewed_head}...${current_head}" --jq '.status // ""' 2>/dev/null) || return 75
		[[ "$compare_status" == "ahead" ]] || return 1
	done < <(printf '%s' "$reviewed_heads_json" | jq -r '.[]' 2>/dev/null)
	return 0
}

_review_feedback_threads_converged() {
	local pr_number="$1"
	local repo_slug="$2"
	local scanner="${PULSE_REVIEW_FEEDBACK_SCANNER:-${BASH_SOURCE[0]%/*}/pr-review-thread-response-scanner.sh}"
	local scan_output=""

	[[ -x "$scanner" ]] || return 75
	scan_output=$(PR_REVIEW_THREAD_RESPONSE_INCLUDE_HUMAN=true \
		"$scanner" scan-pr "$repo_slug" "$pr_number" 2>>"$LOGFILE") || return 75
	[[ -z "$scan_output" ]] || return 1
	return 0
}

_review_feedback_required_checks_green() {
	local pr_number="$1"
	local repo_slug="$2"
	local checks_json=""
	local checks_rc=0

	declare -F gh_pr_checks_exact_json >/dev/null 2>&1 || return 75
	checks_json=$(gh_pr_checks_exact_json "$repo_slug" "$pr_number" required 2>/dev/null) || checks_rc=$?
	case "$checks_rc" in
	0 | 1 | 8) ;;
	*) return 75 ;;
	esac
	[[ -n "$checks_json" ]] || checks_json="[]"
	printf '%s' "$checks_json" | jq -e 'type == ([] | type)' >/dev/null 2>&1 || return 75
	if [[ "$checks_rc" -eq 1 && "$checks_json" == "[]" ]]; then
		return 0
	fi
	printf '%s' "$checks_json" | jq -e 'any(.[]?; .bucket == "fail")' >/dev/null 2>&1 && return 1
	printf '%s' "$checks_json" | jq -e 'any(.[]?; .bucket == "cancel")' >/dev/null 2>&1 && return 75
	[[ "$checks_rc" -eq 0 ]] || return 75
	printf '%s' "$checks_json" | jq -e 'any(.[]?; .bucket == "pending")' >/dev/null 2>&1 && return 75
	return 0
}

_review_feedback_pending_reviewers() {
	local reviewers_json="$1"
	local requested_reviewers_csv="$2"

	jq -nr --argjson reviewers "$reviewers_json" --arg requested "$requested_reviewers_csv" '
		($requested | split("|") | map(select(length > 0))) as $already
		| [$reviewers[] as $reviewer | select(($already | index($reviewer)) == null) | $reviewer]
		| unique | join(",")
	' 2>/dev/null
	return $?
}

_review_feedback_ready_snapshot() {
	local pr_number="$1"
	local repo_slug="$2"

	_pmf_gh_read gh api "repos/${repo_slug}/pulls/${pr_number}" --jq '
		[
			(if .merged_at != null then "MERGED" else ((.state // "") | ascii_upcase) end),
			(.draft | tostring),
			(.head.sha // ""),
			([.requested_reviewers[].login] | join("|")),
			([.labels[].name] | join(","))
		] | join("\u001f")
	' 2>/dev/null
	return $?
}

_review_feedback_ready_snapshot_matches() {
	local snapshot="$1"
	local expected_head="$2"
	local requested_var="$3"
	local pr_state="" is_draft="" current_head="" observed_reviewers="" labels=""

	IFS=$'\x1f' read -r pr_state is_draft current_head observed_reviewers labels <<<"$snapshot"
	[[ "$pr_state" == "OPEN" && "$is_draft" == "false" && "$current_head" == "$expected_head" ]] || return 1
	declare -F _feedback_route_labels_allow_worker_route >/dev/null 2>&1 || return 1
	_feedback_route_labels_allow_worker_route "$labels" || return 1
	printf -v "$requested_var" '%s' "$observed_reviewers"
	return 0
}

_review_feedback_preserve_ready_pr() {
	local pr_number="$1"
	local repo_slug="$2"
	local expected_head="$3"
	local evidence=""
	local reviewers_json="[]"
	local reviewed_heads_json="[]"
	local snapshot=""
	local current_head="" requested_reviewers=""
	local pending_reviewers=""
	local readiness_rc=0

	evidence=$(_review_feedback_ready_reviewer_evidence "$pr_number" "$repo_slug") || return 75
	reviewers_json=$(printf '%s' "$evidence" | jq -c '.reviewers' 2>/dev/null) || return 75
	reviewed_heads_json=$(printf '%s' "$evidence" | jq -c '.reviewed_heads' 2>/dev/null) || return 75
	[[ "$(printf '%s' "$reviewers_json" | jq 'length' 2>/dev/null)" =~ ^[1-9][0-9]*$ ]] || return "$PULSE_REVIEW_FEEDBACK_NO_TRUSTED_REVIEW_RC"
	[[ "$expected_head" =~ ^[0-9a-fA-F]{40}$ ]] || return 75
	snapshot=$(_review_feedback_ready_snapshot "$pr_number" "$repo_slug") || return 75
	_review_feedback_ready_snapshot_matches "$snapshot" "$expected_head" requested_reviewers || return 75
	current_head="$expected_head"

	_review_feedback_head_advances_reviews "$repo_slug" "$current_head" "$reviewed_heads_json" || readiness_rc=$?
	[[ "$readiness_rc" -eq 0 ]] || return "$readiness_rc"
	_review_feedback_threads_converged "$pr_number" "$repo_slug" || readiness_rc=$?
	[[ "$readiness_rc" -eq 0 ]] || return "$readiness_rc"
	_review_feedback_required_checks_green "$pr_number" "$repo_slug" || readiness_rc=$?
	[[ "$readiness_rc" -eq 0 ]] || return "$readiness_rc"
	snapshot=$(_review_feedback_ready_snapshot "$pr_number" "$repo_slug") || return 75
	_review_feedback_ready_snapshot_matches "$snapshot" "$expected_head" requested_reviewers || return 75
	pending_reviewers=$(_review_feedback_pending_reviewers "$reviewers_json" "$requested_reviewers") || return 75
	if [[ -n "$pending_reviewers" ]]; then
		if ! declare -F _feedback_route_gh_write >/dev/null 2>&1 ||
			! _feedback_route_gh_write pr edit "$pr_number" --repo "$repo_slug" \
				--add-reviewer "$pending_reviewers" >/dev/null 2>&1; then
			echo "[pulse-wrapper] review feedback: ready PR #${pr_number} in ${repo_slug} could not re-request trusted reviewer(s); preserving PR for retry" >>"$LOGFILE"
			return 0
		fi
		echo "[pulse-wrapper] review feedback: ready PR #${pr_number} in ${repo_slug} re-requested trusted reviewer(s) for changed head ${current_head}; preserving PR" >>"$LOGFILE"
	else
		echo "[pulse-wrapper] review feedback: ready PR #${pr_number} in ${repo_slug} already awaits its trusted reviewer(s) on changed head ${current_head}; preserving PR" >>"$LOGFILE"
	fi
	snapshot=$(_review_feedback_ready_snapshot "$pr_number" "$repo_slug") || return 75
	_review_feedback_ready_snapshot_matches "$snapshot" "$expected_head" requested_reviewers || return 75
	pending_reviewers=$(_review_feedback_pending_reviewers "$reviewers_json" "$requested_reviewers") || return 75
	[[ -z "$pending_reviewers" ]] || return 75
	return 0
}

_review_feedback_route_preclose_allows() {
	local pr_number="$1"
	local repo_slug="$2"
	local expected_head="$3"
	local readiness_rc=0

	_review_feedback_preserve_ready_pr "$pr_number" "$repo_slug" "$expected_head" || readiness_rc=$?
	[[ "$readiness_rc" -eq 1 ]] || return 75
	return 0
}

_review_feedback_route_initial_gate() {
	local pr_number="$1"
	local repo_slug="$2"
	local expected_head="$3"
	local readiness_rc=0

	_PULSE_FEEDBACK_ROUTE_REVIEW_PRECLOSE_GUARD=0
	_review_feedback_preserve_ready_pr "$pr_number" "$repo_slug" "$expected_head" || readiness_rc=$?
	[[ "$readiness_rc" -ne 0 ]] || return 0
	if [[ "$readiness_rc" -eq "${PULSE_FEEDBACK_ROUTE_DEFERRED_RC:-75}" ]]; then
		echo "[pulse-wrapper] _dispatch_pr_fix_worker: ready-review evidence unavailable for PR #${pr_number} in ${repo_slug} — deferring without destructive routing" >>"$LOGFILE"
		return "${PULSE_FEEDBACK_ROUTE_DEFERRED_RC:-75}"
	fi
	[[ "$readiness_rc" -eq "$PULSE_REVIEW_FEEDBACK_NO_TRUSTED_REVIEW_RC" ]] || _PULSE_FEEDBACK_ROUTE_REVIEW_PRECLOSE_GUARD=1
	return 1
}

_review_feedback_route_before_finalization() {
	local pr_number="$1"
	local repo_slug="$2"
	local expected_head="$3"

	[[ "${_PULSE_FEEDBACK_ROUTE_REVIEW_PRECLOSE_GUARD:-0}" == "1" ]] || return 0
	_review_feedback_route_preclose_allows "$pr_number" "$repo_slug" "$expected_head" && return 0
	echo "[pulse-wrapper] _dispatch_pr_fix_worker: review readiness changed before finalization for PR #${pr_number} in ${repo_slug} — deferring without destructive routing" >>"$LOGFILE"
	return "${PULSE_FEEDBACK_ROUTE_DEFERRED_RC:-75}"
}

_PULSE_REVIEW_FEEDBACK_REVIEWS_JSON="[]"
_PULSE_REVIEW_FEEDBACK_INLINE_JSON="[]"

_review_feedback_merge_paginated_arrays() {
	local pages_json="$1"

	printf '%s\n' "$pages_json" | jq -cs '
		if all(.[]; type == "array") then (add // [])
		else error("expected paginated JSON arrays") end
	' 2>/dev/null
	return $?
}

_review_feedback_fetch_evidence() {
	local pr_number="$1"
	local repo_slug="$2"
	local reviews_rc=0
	local inline_rc=0
	local reviews_pages=""
	local inline_pages=""

	_PULSE_REVIEW_FEEDBACK_REVIEWS_JSON=""
	_PULSE_REVIEW_FEEDBACK_INLINE_JSON=""
	reviews_pages=$(_gh_with_timeout read gh api \
		"repos/${repo_slug}/pulls/${pr_number}/reviews" --paginate \
		--jq '[.[] | select(.state == "CHANGES_REQUESTED" or ((.body // "") | length) > 30)
			| {id: (.id // "" | tostring), author: (.user.login // "unknown"), state: .state,
			   body: (.body // ""), url: (.html_url // ""),
			   submitted_at: (.submitted_at // ""), commit_id: (.commit_id // "")}]' \
		2>/dev/null) || reviews_rc=$?
	inline_pages=$(_gh_with_timeout read gh api \
		"repos/${repo_slug}/pulls/${pr_number}/comments" --paginate \
		--jq '[.[] | {id: (.id // "" | tostring), author: (.user.login // "unknown"),
			path: (.path // ""), line: (.line // .original_line // 0),
			body: (.body // ""), url: (.html_url // ""),
			updated_at: (.updated_at // ""), commit_id: (.commit_id // "")}]' \
		2>/dev/null) || inline_rc=$?
	if [[ "$reviews_rc" -eq 0 ]]; then
		_PULSE_REVIEW_FEEDBACK_REVIEWS_JSON=$(_review_feedback_merge_paginated_arrays "$reviews_pages") || reviews_rc=$?
	fi
	if [[ "$inline_rc" -eq 0 ]]; then
		_PULSE_REVIEW_FEEDBACK_INLINE_JSON=$(_review_feedback_merge_paginated_arrays "$inline_pages") || inline_rc=$?
	fi
	[[ -n "$_PULSE_REVIEW_FEEDBACK_REVIEWS_JSON" ]] || _PULSE_REVIEW_FEEDBACK_REVIEWS_JSON="[]"
	[[ -n "$_PULSE_REVIEW_FEEDBACK_INLINE_JSON" ]] || _PULSE_REVIEW_FEEDBACK_INLINE_JSON="[]"
	if [[ "$reviews_rc" -ne 0 || "$inline_rc" -ne 0 ]]; then
		echo "[pulse-wrapper] _dispatch_pr_fix_worker: review evidence unavailable for PR #${pr_number} in ${repo_slug} (reviews_rc=${reviews_rc}, inline_rc=${inline_rc}) — deferring without routing" >>"$LOGFILE"
		return 1
	fi
	return 0
}

#######################################
# Append a feedback section to a linked issue body, guarded by a marker
# comment for idempotency and with a t2383 fail-safe against body
# clobbering when the issue fetch fails.
#
# Shared by _dispatch_ci_fix_worker, _dispatch_conflict_fix_worker, and
# _dispatch_pr_fix_worker.
#
# Args:
#   $1 - linked_issue  (issue number)
#   $2 - repo_slug     (owner/repo)
#   $3 - marker        (HTML comment marker string)
#   $4 - feedback_section (markdown to append)
#   $5 - caller        (calling function name, for log messages)
#
# Returns: 0 on success or skip (already present), otherwise the underlying
# read/write failure status so transient deferrals remain distinguishable.
#######################################
_append_feedback_to_issue() {
	local linked_issue="$1"
	local repo_slug="$2"
	local marker="$3"
	local feedback_section="$4"
	local caller="$5"

	# t2383 Fix 5: fail-safe — skip body edit when issue fetch fails to
	# prevent clobbering the issue body with only the routed-feedback section.
	local current_body="" fetch_rc=""
	fetch_rc=0
	current_body=$(gh issue view "$linked_issue" --repo "$repo_slug" \
		--json body --jq '.body // ""' 2>/dev/null) || fetch_rc=$?
	if [[ $fetch_rc -ne 0 ]]; then
		echo "[pulse-wrapper] ${caller}: failed to fetch issue #${linked_issue} body (exit ${fetch_rc}) — skipping body edit to prevent data loss (t2383)" >>"$LOGFILE"
		return "$fetch_rc"
	fi

	if printf '%s' "$current_body" | grep -qF "$marker"; then
		# Keep the "routed feedback marker" phrase stable for operator log
		# greps and regression tests (GH#20057): the pre-split dispatch
		# functions all logged a variant of "already has … feedback …".
		echo "[pulse-wrapper] ${caller}: issue #${linked_issue} already has routed feedback marker for this PR — skipping" >>"$LOGFILE"
		return 0
	fi

	local new_body="${current_body}

${marker}
${feedback_section}"
	# Use gh_issue_edit_safe (not bare `gh issue edit`) so the REST fallback
	# in shared-gh-wrappers-safe-edit.sh fires when GraphQL is rate-limited.
	# Bare `gh issue edit` always uses GraphQL and silently fails the body
	# update when the 5000/hr GraphQL budget is exhausted. PR #21733 model.
	local update_rc=0
	gh_issue_edit_safe "$linked_issue" --repo "$repo_slug" \
		--body "$new_body" >/dev/null 2>&1 || update_rc=$?
	if [[ "$update_rc" -ne 0 ]]; then
		echo "[pulse-wrapper] ${caller}: failed to update issue #${linked_issue} body (exit ${update_rc}) — aborting" >>"$LOGFILE"
		return "$update_rc"
	fi
	return 0
}

#######################################
# Transition a linked issue to status:available and add a source label
# so the dispatch queue can re-pick the work.
#
# Uses set_issue_status when available (atomically clears other status
# labels), falls back to direct gh label ops in degraded environments.
#
# Args:
#   $1 - linked_issue  (issue number)
#   $2 - repo_slug     (owner/repo)
#   $3 - source_label  (e.g. "source:ci-feedback")
#   $4 - clear_hold    (optional: 1 removes hold-for-review on recovery)
#   $5 - companion_source_label (optional compatibility provenance)
#######################################
_transition_issue_for_redispatch() {
	local linked_issue="$1"
	local repo_slug="$2"
	local source_label="$3"
	local clear_hold="${4:-0}"
	local companion_source_label="${5:-}"
	local _assignees=""
	_feedback_route_owner_allows "$linked_issue" "$repo_slug" || return "${PULSE_FEEDBACK_ROUTE_DEFERRED_RC:-75}"
	_assignees=$(gh issue view "$linked_issue" --repo "$repo_slug" --json assignees --jq '.assignees[].login' 2>/dev/null) || _assignees=""

	local -a _redispatch_flags=(
		--add-label "origin:worker"
		--remove-label "origin:interactive"
		--remove-label "origin:worker-takeover"
	)
	if [[ -n "$companion_source_label" && "$companion_source_label" != "$source_label" ]]; then
		_redispatch_flags+=(--add-label "$companion_source_label")
	fi
	local _assignee
	while IFS= read -r _assignee; do
		[[ -n "$_assignee" ]] && _redispatch_flags+=(--remove-assignee "$_assignee")
	done <<<"$_assignees"
	if [[ "$clear_hold" == "1" ]]; then
		_redispatch_flags+=(--remove-label "hold-for-review")
	fi

	# Recheck after collecting assignees/flags, immediately before the write. A
	# claim arriving during that read must not be removed by stale routing state.
	_feedback_route_owner_allows "$linked_issue" "$repo_slug" || return "${PULSE_FEEDBACK_ROUTE_DEFERRED_RC:-75}"
	if declare -F set_issue_status >/dev/null 2>&1; then
		if ! set_issue_status "$linked_issue" "$repo_slug" "available" \
			--add-label "$source_label" "${_redispatch_flags[@]}" >/dev/null 2>&1; then
			echo "[pulse-wrapper] feedback finalizer: failed to transition issue #${linked_issue} in ${repo_slug} to status:available" >>"$LOGFILE"
			return 1
		fi
	else
		if ! _feedback_route_gh_write issue edit "$linked_issue" --repo "$repo_slug" \
			--add-label "status:available" --add-label "$source_label" \
			"${_redispatch_flags[@]}" \
			--remove-label "status:queued" --remove-label "status:in-progress" \
			--remove-label "status:in-review" --remove-label "status:claimed" \
			>/dev/null 2>&1; then
			echo "[pulse-wrapper] feedback finalizer: fallback transition failed for issue #${linked_issue} in ${repo_slug}" >>"$LOGFILE"
			return 1
		fi
	fi
	return 0
}
#######################################
# Route review feedback from a stuck worker PR to its linked issue and
# close the PR so the dispatch queue can re-pick the task (t2093).
#
# Called by `_check_pr_merge_gates` when `reviewDecision=CHANGES_REQUESTED`
# on a worker-authored PR with a linked issue. Before this helper existed,
# such PRs accumulated indefinitely: the merge pass skipped them (correctly,
# since they can't pass the review gate as-is), but nothing dispatched a
# fresh worker to address the feedback. The PR author is the headless
# worker account, so no human was notified; the review-followup pipeline
# only fires on *merged* PRs; and the dispatch-dedup guard treated the
# open PR as an active claim on the linked issue.
#
# This function closes that loop:
#   1. Fetches bot reviews + inline comments from the stuck PR.
#   2. Appends a "Review Feedback" section to the linked issue body
#      (marker-guarded so re-runs are idempotent).
#   3. Transitions the linked issue to `status:available` and tags it
#      `source:review-feedback` so the next dispatch cycle picks it up
#      with the feedback in the prompt.
#   4. Closes the stuck PR with an explanatory comment and tags it
#      `review-routed-to-issue` as a belt-and-suspenders idempotency flag.
#
# Interactive, external-contributor, no-takeover, and maintainer-held PRs are
# filtered by `_route_pr_to_fix_worker` before this helper is called.
#
# Partial finalization returns a typed deferred or maintainer outcome. The
# merge-loop boundary logs that outcome and continues processing unrelated PRs.
#
# Reference patterns:
#   - `quality-feedback-helper.sh` — bot review comment extraction
#   - `_close_conflicting_pr`      — close-with-comment boilerplate
#   - `draft-response-helper.sh`   — issue body append pattern
#
# Args:
#   $1 - pr_number
#   $2 - repo_slug  (owner/repo)
#   $3 - linked_issue  (the issue the PR resolves/fixes/closes)
#######################################
_dispatch_pr_fix_worker() {
	local pr_number="$1"
	local repo_slug="$2"
	local linked_issue="$3"

	[[ "$pr_number" =~ ^[0-9]+$ ]] || return 0
	[[ -n "$repo_slug" ]] || return 0
	[[ "$linked_issue" =~ ^[0-9]+$ ]] || return 0
	if ! declare -F _finalize_feedback_route >/dev/null 2>&1; then
		echo "[pulse-wrapper] _dispatch_pr_fix_worker: feedback finalizer unavailable for PR #${pr_number} in ${repo_slug}" >>"$LOGFILE"
		return "${PULSE_FEEDBACK_ROUTE_DEFERRED_RC:-75}"
	fi
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		echo "[pulse-wrapper] feedback finalizer: deferred PR #${pr_number} and issue #${linked_issue} in ${repo_slug} — dry-run forbids review feedback finalization writes" >>"$LOGFILE"
		return "${PULSE_FEEDBACK_ROUTE_DEFERRED_RC:-75}"
	fi
	local route_snapshot=""
	local route_state=""
	local expected_head=""
	local route_labels=""
	route_snapshot=$(_feedback_route_pr_snapshot "$pr_number" "$repo_slug") || {
		_feedback_route_defer "$pr_number" "$repo_slug" "$linked_issue" "initial review-route PR snapshot unavailable"
		return $?
	}
	IFS=$'\t' read -r route_state expected_head route_labels <<<"$route_snapshot"

	# Ensure the idempotency + origin labels exist on the repo (idempotent,
	# --force, swallowed failures). quality-feedback-helper.sh also creates
	# source:review-feedback — redundant creation is harmless.
	_feedback_route_gh_write label create "review-routed-to-issue" --repo "$repo_slug" --color "D93F0B" \
		--description "Worker PR with CHANGES_REQUESTED routed to linked issue for re-dispatch (t2093)" \
		--force >/dev/null 2>&1 || true
	_feedback_route_gh_write label create "source:review-feedback" --repo "$repo_slug" --color "C2E0C6" \
		--description "Issue carries review feedback routed from a closed worker PR" \
		--force >/dev/null 2>&1 || true
	_feedback_route_gh_write label create "$PULSE_REVIEW_REPAIR_SOURCE_LABEL" --repo "$repo_slug" --color "C2E0C6" \
		--description "Verified head-bound PR review repair" \
		--force >/dev/null 2>&1 || true

	if ! _review_feedback_fetch_evidence "$pr_number" "$repo_slug"; then
		return "${PULSE_FEEDBACK_ROUTE_DEFERRED_RC:-75}"
	fi
	local reviews_json="$_PULSE_REVIEW_FEEDBACK_REVIEWS_JSON"
	local inline_json="$_PULSE_REVIEW_FEEDBACK_INLINE_JSON"
	local readiness_rc=0
	_review_feedback_route_initial_gate "$pr_number" "$repo_slug" "$expected_head" || readiness_rc=$?
	if [[ "$readiness_rc" -eq 0 ]]; then
		return 0
	fi
	[[ "$readiness_rc" -eq 1 ]] || return "$readiness_rc"

	# --- Build the Review Feedback markdown section ---
	local feedback_section=""
	feedback_section=$(_build_review_feedback_section \
		"$pr_number" "$repo_slug" "$reviews_json" "$inline_json") || feedback_section=""
	if [[ -z "$feedback_section" ]]; then
		echo "[pulse-wrapper] _dispatch_pr_fix_worker: PR #${pr_number} in ${repo_slug} has CHANGES_REQUESTED but no substantive review content — leaving PR open without routing (t2093)" >>"$LOGFILE"
		return 0
	fi

	local evidence_fingerprint=""
	evidence_fingerprint=$(_review_feedback_evidence_fingerprint "$reviews_json" "$inline_json") || {
		echo "[pulse-wrapper] _dispatch_pr_fix_worker: review evidence identity unavailable for PR #${pr_number} in ${repo_slug} — deferring without routing" >>"$LOGFILE"
		return "${PULSE_FEEDBACK_ROUTE_DEFERRED_RC:-75}"
	}
	local marker="<!-- t2093:review-feedback:PR${pr_number}:EVIDENCE${evidence_fingerprint} -->"
	local legacy_match="<!-- t2093:review-feedback:PR${pr_number} -->"
	local close_comment
	close_comment="## Review feedback routed to linked issue #${linked_issue} (t2093)

This worker-authored PR had \`reviewDecision=CHANGES_REQUESTED\`. Rather than let it sit
indefinitely (no human owns worker PRs and the dispatch-dedup guard treats an open worker
PR as an active claim), the deterministic merge pass has:

1. Extracted the review feedback (top-level reviews + file:line inline comments) and
   appended it to the linked issue body as a \"Review Feedback\" section.
2. Closed this PR so the dispatch queue can re-pick the linked issue.
3. Transitioned issue #${linked_issue} to \`status:available\` and tagged it with
   verified \`source:review-repair\` provenance plus \`source:review-feedback\`.
   The next pulse cycle can dispatch a fresh worker with the feedback in its prompt.

The next worker will see the updated issue body, address the review findings, and
open a fresh PR against issue #${linked_issue}.

_Closed by deterministic merge pass (pulse-merge.sh, t2093)._"
	local finalize_rc=0
	_review_feedback_route_before_finalization "$pr_number" "$repo_slug" "$expected_head" || return $?
	_finalize_feedback_route "review" "$pr_number" "$repo_slug" "$linked_issue" "$expected_head" \
		"$PULSE_REVIEW_REPAIR_SOURCE_LABEL" "review-routed-to-issue" "$marker" "$feedback_section" \
		"_dispatch_pr_fix_worker" "$close_comment" "$legacy_match" "$evidence_fingerprint" \
		"source:review-feedback" || finalize_rc=$?
	_PULSE_FEEDBACK_ROUTE_REVIEW_PRECLOSE_GUARD=0
	if [[ "$finalize_rc" -eq 0 ]]; then
		echo "[pulse-wrapper] _dispatch_pr_fix_worker: routed review feedback from PR #${pr_number} to issue #${linked_issue} in ${repo_slug} (t2093)" >>"$LOGFILE"
	fi
	return "$finalize_rc"
}
