#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
# Protected-default TODO publication: persist an isolated Pulse projection as
# a reviewable PR, never as a successful default-branch publication.

_PULSE_TODO_HANDOFF_PENDING="pending"

_pulse_todo_handoff_identity() {
	local workspace="$1" repo_slug="$2" base_sha="$3" changed_paths="$4"
	local snapshot="" digest=""
	snapshot=$(mktemp "${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}/pulse-handoff.XXXXXX") || return 1
	if ! _planning_publish_snapshot_readonly "$workspace" "$changed_paths" "$snapshot" planning; then
		rm -f "$snapshot"
		return 1
	fi
	digest=$( { printf '%s\n%s\n' "$repo_slug" "$base_sha"; sort "$snapshot"; } |
		git -C "$workspace" hash-object --stdin) || { rm -f "$snapshot"; return 1; }
	rm -f "$snapshot"
	_PULSE_TODO_HANDOFF_ID="$digest"
	_PULSE_TODO_HANDOFF_BRANCH="aidevops/pulse-todo-${digest:0:16}"
	return 0
}

_pulse_todo_handoff_existing() {
	local repo_slug="$1" default_branch="$2" branch="$3" handoff_id="$4"
	local existing="" count=0 state="" body="" pending="" matches=""
	_PULSE_TODO_HANDOFF_URL=""
	_PULSE_TODO_HANDOFF_STATE="absent"
	# Default may advance while the first handoff is awaiting review. Its
	# snapshot-derived branch then differs, but a second PR would compete with
	# the pending projection. Fail closed if the bounded listing is saturated.
	pending=$(gh pr list --repo "$repo_slug" --base "$default_branch" --state open \
		--json url,state,body,headRefName --limit 100) || return 1
	count=$(printf '%s\n' "$pending" | jq 'length') || return 1
	[[ "$count" -lt 100 ]] || return 1
	matches=$(printf '%s\n' "$pending" | jq \
		'[.[] | select(.state == "OPEN" and
			(.headRefName // "" | startswith("aidevops/pulse-todo-")) and
			(.body // "" | test("<!-- aidevops:pulse-todo-handoff id=[0-9a-f]{40} -->"))) ]') || return 1
	count=$(printf '%s\n' "$matches" | jq 'length') || return 1
	[[ "$count" -le 1 ]] || return 1
	if [[ "$count" -eq 1 ]]; then
		_PULSE_TODO_HANDOFF_URL=$(printf '%s\n' "$matches" | jq -r '.[0].url') || return 1
		[[ -n "$_PULSE_TODO_HANDOFF_URL" ]] || return 1
		_PULSE_TODO_HANDOFF_STATE="$_PULSE_TODO_HANDOFF_PENDING"
		return 0
	fi
	existing=$(gh pr list --repo "$repo_slug" --head "$branch" --base "$default_branch" \
		--state all --json url,state,body --limit 10) || return 1
	count=$(printf '%s\n' "$existing" | jq 'length') || return 1
	[[ "$count" -le 1 ]] || return 1
	[[ "$count" -ne 0 ]] || return 0
	state=$(printf '%s\n' "$existing" | jq -r '.[0].state') || return 1
	body=$(printf '%s\n' "$existing" | jq -r '.[0].body') || return 1
	[[ "$body" == *"<!-- aidevops:pulse-todo-handoff id=${handoff_id} -->"* ]] || return 1
	_PULSE_TODO_HANDOFF_URL=$(printf '%s\n' "$existing" | jq -r '.[0].url') || return 1
	case "$state" in
	OPEN) _PULSE_TODO_HANDOFF_STATE="$_PULSE_TODO_HANDOFF_PENDING" ;;
	*) _PULSE_TODO_HANDOFF_STATE="closed" ;;
	esac
	return 0
}

_pulse_todo_handoff_linkage() {
	local workspace="$1" refs="" issue_num=""
	refs=$(git -C "$workspace" diff --unified=0 HEAD -- TODO.md |
		grep -E '^\+[^+]' | grep -oE 'ref:GH#[0-9]+' |
		grep -oE '[0-9]+' | LC_ALL=C sort -nu) || return 1
	[[ -n "$refs" ]] || return 1
	while IFS= read -r issue_num; do
		[[ "$issue_num" =~ ^[1-9][0-9]*$ ]] || return 1
		printf -- '- Ref #%s\n' "$issue_num"
	done <<<"$refs"
	return 0
}

# Called on every changed snapshot before the default push and again on GH006.
# Return 0 only when an existing reviewable handoff is pending; return 4 after
# creating one; return 1 for unsafe or unavailable publication.
pulse_todo_publication_handoff() {
	local workspace="$1" repo_slug="$2" default_branch="$3" base_sha="$4" changed_paths="$5" mode="$6"
	local branch="" handoff_id="" linkage="" body_file="" pr_url="" publish_rc=0
	local remote_branch="" permission="" issue_num=""
	[[ "$repo_slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && -n "$changed_paths" ]] || return 1
	_pulse_todo_handoff_identity "$workspace" "$repo_slug" "$base_sha" "$changed_paths" || return 1
	branch="$_PULSE_TODO_HANDOFF_BRANCH"; handoff_id="$_PULSE_TODO_HANDOFF_ID"
	_pulse_todo_handoff_existing "$repo_slug" "$default_branch" "$branch" "$handoff_id" || return 1
	[[ "$_PULSE_TODO_HANDOFF_STATE" != "$_PULSE_TODO_HANDOFF_PENDING" ]] || return 0
	[[ "$_PULSE_TODO_HANDOFF_STATE" != "closed" ]] || return 1
	[[ "$mode" == "publish" ]] || return 4
	permission=$(gh repo view "$repo_slug" --json viewerPermission --jq '.viewerPermission') || return 1
	case "$permission" in ADMIN | MAINTAIN | WRITE) ;; *) return 1 ;; esac
	linkage=$(_pulse_todo_handoff_linkage "$workspace") || return 1
	issue_num=$(printf '%s\n' "$linkage" | grep -oE '#[0-9]+' | grep -oE '[0-9]+' | head -1) || return 1
	remote_branch=$(git -C "$workspace" ls-remote --heads origin "refs/heads/${branch}") || return 1
	if [[ -n "$remote_branch" ]]; then
		git -C "$workspace" fetch -q origin "$branch" || return 1
		git -C "$workspace" log -1 --format=%B FETCH_HEAD |
			grep -Fqx "Pulse-TODO-Handoff-ID: ${handoff_id}" || return 1
	fi
	_pulse_todo_sync_exact_default_snapshot "$workspace" "$default_branch" "$base_sha" || return 1
	AIDEVOPS_PLANNING_PARENT_BRANCH="$default_branch" \
		AIDEVOPS_PLANNING_BASE_SHA="$base_sha" PLANNING_PUBLISH_MAX_RETRIES=1 \
		planning_publish "$workspace" "chore: sync GitHub issue refs to TODO.md
Pulse-TODO-Handoff-ID: ${handoff_id}" origin "$branch" "$changed_paths" || publish_rc=$?
	[[ "$publish_rc" -eq 0 ]] || return 1
	# Confirm that the candidate is still a planning-only projection before PR creation.
	[[ -n "$PLANNING_PUBLISHED_COMMIT" ]] || return 1
	body_file=$(mktemp "${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}/pulse-pr.XXXXXX") || return 1
	{
		printf '<!-- aidevops:pulse-todo-handoff id=%s -->\n' "$handoff_id"
		# shellcheck disable=SC2016 # Backticks in the Markdown body are literal.
		printf '## Pulse TODO publication\n\nValidated allowlisted planning changes from default-base `%s` are pending review. This PR is not a completed TODO update. Required checks, linked-issue and maintainer gates still apply.\n\n' "$base_sha"
		printf '## Related issues\n\n%s\n' "$linkage"
	} >"$body_file"
	# The wrapper supplies the signature, origin and policy checks at publication.
	if ! declare -F gh_create_pr >/dev/null 2>&1; then
		# shellcheck source=shared-gh-wrappers.sh
		source "${BASH_SOURCE[0]%/*}/shared-gh-wrappers.sh"
	fi
	pr_url=$(AIDEVOPS_PR_CREATE_READY=1 gh_create_pr --repo "$repo_slug" \
		--base "$default_branch" --head "$branch" \
		--title "GH#${issue_num}: sync verified TODO refs" \
		--body-file "$body_file") || pr_url=""
	rm -f "$body_file"
	if [[ -z "$pr_url" ]]; then
		_pulse_todo_handoff_existing "$repo_slug" "$default_branch" "$branch" "$handoff_id" || return 1
		[[ "$_PULSE_TODO_HANDOFF_STATE" == "$_PULSE_TODO_HANDOFF_PENDING" ]] || return 1
	else
		_PULSE_TODO_HANDOFF_URL="$pr_url"
		_PULSE_TODO_HANDOFF_STATE="$_PULSE_TODO_HANDOFF_PENDING"
	fi
	return 4
}
