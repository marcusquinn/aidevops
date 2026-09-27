#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-dispatch-brief-scope.sh — self-healing for missing_files_scope brief
# holds (GH#32689).
#
# The pre-claim scope gate (GH#32531/GH#32598) holds auto-dispatch briefs that
# lack a canonical Files Scope. Two gaps turned that gate into manual toil:
#   1. Briefs with explicit "Files to Modify" EDIT:/NEW: declarations were held
#      even though brief-readiness-helper.sh scope-normalize derives the exact
#      canonical scope from them (claim-task-id.sh already normalizes).
#   2. status:blocked never cleared after the brief owner repaired the body.
#
# This module is sourced by pulse-dispatch-core.sh. Depends on gh, jq,
# gh_issue_edit_safe, gh_issue_comment, set_issue_status,
# repo_allows_pulse_write_actions, and core's _dispatch_brief_hold_body_hash /
# _dispatch_brief_hold_recorded.
#
# Functions in this module (in source order):
#   - _brief_scope_author_trusted
#   - _brief_scope_passes
#   - _brief_scope_normalized_body
#   - _dispatch_brief_scope_self_heal
#   - _brief_scope_hold_is_latest_blocker
#   - _release_repaired_brief_hold
#   - _release_repaired_brief_holds_repo
#   - release_repaired_brief_holds

[[ -n "${_PULSE_DISPATCH_BRIEF_SCOPE_LOADED:-}" ]] && return 0
_PULSE_DISPATCH_BRIEF_SCOPE_LOADED=1

_BRIEF_SCOPE_SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
_BRIEF_SCOPE_HOLD_MARKER='aidevops:brief-hold reason=missing_files_scope'
# Trusted comment content that means something newer than the brief hold owns
# the blocked state (dispatch attempts, worker/watchdog/stale/breaker blocks,
# permission or human holds). Any match after the hold keeps the issue blocked.
_BRIEF_SCOPE_LATER_BLOCKERS='ops:start|status:blocked|Dispatching worker|CLAIM_|Worker Watchdog Kill|Terminal blocker|ACTION REQUIRED|HUMAN_UNBLOCK_REQUIRED|STALE_'

# aidevops:trust-boundary — only briefs authored by write-capable collaborators
# may be held, rewritten or released by the pulse; everything else stays on the
# normal external-review path.
_brief_scope_author_trusted() {
	local repo_slug="$1"
	local author="$2"
	local permission=""
	[[ "$author" =~ ^[A-Za-z0-9-]+$ ]] || return 1
	permission=$(gh api "repos/${repo_slug}/collaborators/${author}/permission" --jq '.permission' 2>/dev/null) || return 1
	case "$permission" in admin | maintain | write) ;; *) return 1 ;; esac
	declare -F repo_allows_pulse_write_actions >/dev/null 2>&1 || return 1
	repo_allows_pulse_write_actions "$repo_slug" || return 1
	return 0
}

# Same validator the pre-claim gate uses, so release and hold never disagree.
_brief_scope_passes() {
	local issue_number="$1"
	local issue_body="$2"
	"${_BRIEF_SCOPE_SCRIPT_DIR}/pre-dispatch-validator-helper.sh" scope-check \
		"$issue_number" "$issue_body" 1 >/dev/null 2>&1
	return $?
}

# Print the normalized body when explicit author declarations derive a canonical
# scope that passes the gate. Pure and local: no GitHub calls.
_brief_scope_normalized_body() {
	local issue_number="$1"
	local issue_body="$2"
	local normalized=""
	normalized=$(bash "${_BRIEF_SCOPE_SCRIPT_DIR}/brief-readiness-helper.sh" \
		scope-normalize "$issue_body" 2>/dev/null) || return 1
	[[ -n "$normalized" && "$normalized" != "$issue_body" ]] || return 1
	_brief_scope_passes "$issue_number" "$normalized" || return 1
	printf '%s' "$normalized"
	return 0
}

# Rewrite a trusted body with its normalized canonical scope, at most once per
# original body hash so an external body sync cannot cause edit churn.
# Returns 0 when the body was rewritten, 1 when the caller must hold instead.
_dispatch_brief_scope_self_heal() {
	local issue_number="$1"
	local repo_slug="$2"
	local issue_body="$3"
	local normalized="" body_hash="" marker="" recorded_rc=0 body_file="" note_file=""
	normalized=$(_brief_scope_normalized_body "$issue_number" "$issue_body") || return 1
	body_hash=$(_dispatch_brief_hold_body_hash "$issue_body") || return 1
	marker="<!-- aidevops:brief-scope-normalized body=${body_hash} -->"
	_dispatch_brief_hold_recorded "$issue_number" "$repo_slug" "$marker" || recorded_rc=$?
	# 0 = this exact body was normalized before and came back; 2 = unreadable.
	[[ "$recorded_rc" -eq 1 ]] || return 1
	body_file=$(mktemp) || return 1
	printf '%s\n' "$normalized" >"$body_file"
	if ! gh_issue_edit_safe "$issue_number" --repo "$repo_slug" --body-file "$body_file" >/dev/null 2>&1; then
		rm -f "$body_file"
		return 1
	fi
	rm -f "$body_file"
	note_file=$(mktemp) || return 0
	# shellcheck disable=SC2016 # literal Markdown backticks, not expansions
	printf '%s\nBrief scope normalized: appended a canonical Files Scope derived from the explicit `EDIT:`/`NEW:` declarations in Files to Modify (line ranges dropped). Edit that section if the intended write surface differs.\n' \
		"$marker" >"$note_file"
	gh_issue_comment "$issue_number" --repo "$repo_slug" --body-file "$note_file" >/dev/null 2>&1 || true
	rm -f "$note_file"
	echo "[dispatch_with_dedup] Brief scope normalized for #${issue_number} in ${repo_slug}; dispatch resumes next cycle (GH#32689)" >>"${LOGFILE:-/dev/null}"
	return 0
}

# Returns 0 only when the most recent trusted missing_files_scope hold is still
# the newest blocking/dispatch signal on the issue.
_brief_scope_hold_is_latest_blocker() {
	local repo_slug="$1"
	local issue_number="$2"
	local comments_json="" verdict=""
	comments_json=$(gh api "repos/${repo_slug}/issues/${issue_number}/comments?per_page=100" \
		--paginate --slurp 2>/dev/null) || return 1
	verdict=$(printf '%s' "$comments_json" | jq -r \
		--arg hold "$_BRIEF_SCOPE_HOLD_MARKER" --arg later "$_BRIEF_SCOPE_LATER_BLOCKERS" '
		arrays
		| (if ([.[0]? | arrays] | length) > 0 then add else . end)
		| map(select((.author_association // "") | IN("OWNER", "MEMBER", "COLLABORATOR")) | (.body // ""))
		| . as $bodies
		| ([range(0; length) | select($bodies[.] | contains($hold))] | last) as $i
		| if $i == null then "absent"
		  elif any($bodies[($i + 1):][]; test($later)) then "superseded"
		  else "brief-hold" end
	' 2>/dev/null) || return 1
	[[ "$verdict" == "brief-hold" ]]
	return $?
}

# Release one held issue whose brief is now scoped (or deterministically
# normalizable). Still-unscoped bodies return before any GitHub call.
_release_repaired_brief_hold() {
	local repo_slug="$1"
	local issue_number="$2"
	local issue_body="$3"
	local author="$4"
	local scoped="false"
	if _brief_scope_passes "$issue_number" "$issue_body"; then
		scoped="true"
	elif ! _brief_scope_normalized_body "$issue_number" "$issue_body" >/dev/null; then
		return 1
	fi
	_brief_scope_hold_is_latest_blocker "$repo_slug" "$issue_number" || return 1
	_brief_scope_author_trusted "$repo_slug" "$author" || return 1
	if [[ "$scoped" != "true" ]]; then
		_dispatch_brief_scope_self_heal "$issue_number" "$repo_slug" "$issue_body" || return 1
	fi
	set_issue_status "$issue_number" "$repo_slug" available >/dev/null || return 1
	echo "[pulse-wrapper] brief-hold-release: #${issue_number} in ${repo_slug} — brief now has a canonical Files Scope; status:blocked → status:available (GH#32689)" >>"${LOGFILE:-/dev/null}"
	return 0
}

_release_repaired_brief_holds_repo() {
	local repo_slug="$1"
	local limit="${PULSE_BRIEF_HOLD_RELEASE_LIMIT:-30}"
	local issues_json="" count=0 idx=0 released=0 row="" number="" body="" author=""
	declare -F repo_allows_pulse_write_actions >/dev/null 2>&1 || return 0
	repo_allows_pulse_write_actions "$repo_slug" || return 0
	issues_json=$(gh issue list --repo "$repo_slug" --state open \
		--label auto-dispatch --label status:blocked --limit "$limit" \
		--json number,body,author,labels 2>/dev/null) || return 0
	# Dependency, permission, review and explicit holds have their own owners.
	issues_json=$(printf '%s' "$issues_json" | jq -c '
		[.[] | select(([.labels[]?.name] | any(
			startswith("needs-") or startswith("blocked-by:") or
			. == "hold-for-review" or . == "no-auto-dispatch" or . == "lockdown")) | not)
		| select((.body // "") | test("(?im)^[[:space:]]*(- )?blocked[- ]by:") | not)]
	' 2>/dev/null) || return 0
	count=$(printf '%s' "$issues_json" | jq 'length' 2>/dev/null) || count=0
	[[ "$count" =~ ^[0-9]+$ ]] || count=0
	while [[ "$idx" -lt "$count" ]]; do
		row=$(printf '%s' "$issues_json" | jq -c --argjson i "$idx" '.[$i]') || break
		idx=$((idx + 1))
		number=$(printf '%s' "$row" | jq -r '.number // empty')
		[[ "$number" =~ ^[0-9]+$ ]] || continue
		body=$(printf '%s' "$row" | jq -r '.body // ""')
		author=$(printf '%s' "$row" | jq -r '.author.login // ""')
		if _release_repaired_brief_hold "$repo_slug" "$number" "$body" "$author"; then
			released=$((released + 1))
		fi
	done
	printf '%s\n' "$released"
	return 0
}

# Pulse stage: iterate the dependency-graph repo set built earlier in the cycle.
release_repaired_brief_holds() {
	local cache_file="${DEP_GRAPH_CACHE_FILE:-}"
	local slugs="" slug="" released="" total=0
	[[ -n "$cache_file" && -f "$cache_file" ]] || return 0
	slugs=$(jq -r '.repos | keys[]' "$cache_file" 2>/dev/null) || return 0
	while IFS= read -r slug; do
		[[ "$slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || continue
		released=$(_release_repaired_brief_holds_repo "$slug") || released=0
		[[ "$released" =~ ^[0-9]+$ ]] && total=$((total + released))
	done <<<"$slugs"
	if [[ "$total" -gt 0 ]]; then
		echo "[pulse-wrapper] brief-hold-release: released ${total} repaired brief hold(s) (GH#32689)" >>"${LOGFILE:-/dev/null}"
	fi
	return 0
}
