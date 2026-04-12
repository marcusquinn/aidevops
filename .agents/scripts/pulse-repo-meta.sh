#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-repo-meta.sh — Repo metadata accessors and dispatchable issue candidate lists.
#
# Extracted from pulse-wrapper.sh in Phase 1 of the phased decomposition
# (parent: GH#18356, plan: todo/plans/pulse-wrapper-decomposition.md §6).
#
# This module is sourced by pulse-wrapper.sh. It MUST NOT be executed
# directly — it relies on the orchestrator having sourced:
#   shared-constants.sh
#   worker-lifecycle-common.sh
# and having defined all PULSE_* / FAST_FAIL_* / etc. configuration
# constants in the bootstrap section.
#
# Functions in this module (in source order):
#   - get_repo_path_by_slug
#   - get_repo_owner_by_slug
#   - get_repo_maintainer_by_slug
#   - get_repo_priority_by_slug
#   - list_dispatchable_issue_candidates_json
#   - list_dispatchable_issue_candidates
#
# This is a pure move from pulse-wrapper.sh. The function bodies are
# byte-identical to their pre-extraction form. Any change must go in a
# separate follow-up PR after the full decomposition (Phase 12) lands.

# Include guard — prevent double-sourcing. pulse-wrapper.sh sources every
# module unconditionally on start, and characterization tests re-source to
# verify idempotency.
[[ -n "${_PULSE_REPO_META_LOADED:-}" ]] && return 0
_PULSE_REPO_META_LOADED=1

#######################################
# Resolve managed repo path from slug
# Arguments:
#   $1 - repo slug (owner/repo)
# Returns: path via stdout (empty if not found)
#######################################
get_repo_path_by_slug() {
	local repo_slug="$1"
	if [[ -z "$repo_slug" ]] || [[ ! -f "$REPOS_JSON" ]]; then
		echo ""
		return 0
	fi

	local repo_path
	repo_path=$(jq -r --arg slug "$repo_slug" '.initialized_repos[] | select(.slug == $slug) | .path' "$REPOS_JSON" 2>/dev/null | head -n 1)
	if [[ "$repo_path" == "null" ]]; then
		repo_path=""
	fi
	echo "$repo_path"
	return 0
}

#######################################
# Resolve repo owner login from slug
# Arguments:
#   $1 - repo slug (owner/repo)
# Returns: owner login via stdout (empty if invalid)
#######################################
get_repo_owner_by_slug() {
	local repo_slug="$1"
	if [[ -z "$repo_slug" ]] || [[ "$repo_slug" != */* ]]; then
		echo ""
		return 0
	fi

	echo "${repo_slug%%/*}"
	return 0
}

#######################################
# Resolve repo maintainer login from repos.json
# Arguments:
#   $1 - repo slug (owner/repo)
# Returns: maintainer login via stdout (empty if missing)
#######################################
get_repo_maintainer_by_slug() {
	local repo_slug="$1"
	if [[ -z "$repo_slug" ]] || [[ ! -f "$REPOS_JSON" ]]; then
		echo ""
		return 0
	fi

	local maintainer
	maintainer=$(jq -r --arg slug "$repo_slug" '.initialized_repos[] | select(.slug == $slug) | .maintainer // empty' "$REPOS_JSON" 2>/dev/null) || maintainer=""
	if [[ "$maintainer" == "null" ]]; then
		maintainer=""
	fi
	printf '%s\n' "$maintainer"
	return 0
}

#######################################
# Resolve repo priority class from repos.json
# Arguments:
#   $1 - repo slug (owner/repo)
# Returns: priority via stdout (product/tooling/profile, default tooling)
#######################################
get_repo_priority_by_slug() {
	local repo_slug="$1"
	if [[ -z "$repo_slug" ]] || [[ ! -f "$REPOS_JSON" ]]; then
		echo "tooling"
		return 0
	fi

	local repo_priority
	repo_priority=$(jq -r --arg slug "$repo_slug" '.initialized_repos[] | select(.slug == $slug) | .priority // "tooling"' "$REPOS_JSON" 2>/dev/null | head -n 1)
	if [[ -z "$repo_priority" || "$repo_priority" == "null" ]]; then
		repo_priority="tooling"
	fi
	printf '%s\n' "$repo_priority"
	return 0
}

#######################################
# Return dispatchable issue candidates as JSON for one repo.
#
# Design: this function is intentionally permissive — it returns all
# open issues that are not in a hard-blocked terminal state. It does NOT
# filter by assignee or active-claim status label. Both are included in
# the output JSON (.assignees and .labels arrays) for use by downstream
# dispatch logic.
#
# The combined "label AND assignee" dedup gate (t1996 canonical rule) is
# enforced downstream by dispatch_with_dedup() → check_dispatch_dedup()
# Layer 6 (dispatch-dedup-helper.sh is-assigned). Applying it here would
# require per-issue API calls on a batch response, which is expensive.
#
# The jq filter excludes only deterministic blockers:
#   - status:blocked (explicit hold)
#   - needs-* (waiting for maintainer action)
#   - supervisor/persistent/routine-tracking (non-work telemetry)
# Everything else passes through for the downstream dedup layers to decide.
#
# Arguments:
#   $1 - repo slug (owner/repo)
#   $2 - max issues to fetch (optional, default 100)
# Returns: JSON array of issue objects (number, title, url, updatedAt, labels, assignees)
#######################################
list_dispatchable_issue_candidates_json() {
	local repo_slug="$1"
	local limit="${2:-100}"

	if [[ -z "$repo_slug" ]]; then
		printf '[]\n'
		return 0
	fi
	[[ "$limit" =~ ^[0-9]+$ ]] || limit=100

	local issue_json issue_dispatch_err
	issue_dispatch_err=$(mktemp)
	issue_json=$(gh issue list --repo "$repo_slug" --state open --json number,title,url,assignees,labels,updatedAt --limit "$limit" 2>"$issue_dispatch_err") || issue_json="[]"
	if [[ -z "$issue_json" || "$issue_json" == "null" ]]; then
		local _issue_dispatch_err_msg
		_issue_dispatch_err_msg=$(cat "$issue_dispatch_err" 2>/dev/null || echo "unknown error")
		echo "[pulse-wrapper] list_dispatchable_issue_candidates: gh issue list FAILED for ${repo_slug}: ${_issue_dispatch_err_msg}" >>"$LOGFILE"
		issue_json="[]"
	fi
	rm -f "$issue_dispatch_err"

	printf '%s' "$issue_json" | jq -c '
		[
			.[] |
			(.labels | map(.name)) as $labels |
			(.assignees | map(.login)) as $assignees |
			select(($labels | index("status:blocked")) == null) |
			select(([$labels[] | select(startswith("needs-"))] | length) == 0) |
			select(($labels | index("supervisor")) == null) |
			select(($labels | index("persistent")) == null) |
			select(($labels | index("routine-tracking")) == null) |
			{
				number,
				title,
				url,
				updatedAt,
				labels: $labels,
				assignees: $assignees
			}
		]
	' 2>/dev/null || printf '[]\n'
	return 0
}

#######################################
# List inactive backlog issues that are eligible for dispatch evaluation
# in a single repo.
#
# Candidate rules:
# - open and not blocked
# - exclude any issue carrying a needs-* label (e.g. needs-maintainer-review)
# - include queued/in-progress/in-review states (status labels are not blockers)
# - include assigned issues (assignment state is resolved by dedup/claim checks)
# - exclude supervisor/persistent telemetry issues
#
# Active PR/worker overlap is handled later by deterministic dedup guards.
# This helper only answers: "should the pulse look at this issue at all?"
#
# Arguments:
#   $1 - repo slug (owner/repo)
#   $2 - max issues to fetch (optional, default 100)
# Returns: pipe-delimited rows number|title|labels|updatedAt
#######################################
list_dispatchable_issue_candidates() {
	local repo_slug="$1"
	local limit="${2:-100}"

	if [[ -z "$repo_slug" ]]; then
		return 0
	fi
	[[ "$limit" =~ ^[0-9]+$ ]] || limit=100

	list_dispatchable_issue_candidates_json "$repo_slug" "$limit" | jq -r '.[] | "\(.number)|\(.title)|\(.labels | join(","))|\(.updatedAt // "")"' 2>/dev/null || true
	return 0
}
