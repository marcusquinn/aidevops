#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# dispatch-dedup-pr.sh — PR evidence dedup checks for dispatch deduplication (GH#18916)
#
# Extracted from dispatch-dedup-helper.sh (GH#18916) to reduce that file below
# the 2000-line simplification gate.
#
# Sourced by dispatch-dedup-helper.sh. Do NOT invoke directly.
#
# Exports:
#   has_open_pr <issue> <slug> [issue-title]
#     Check whether an issue already has open or merged PR evidence.
#     Exit 0 = PR evidence exists (do NOT dispatch), exit 1 = no evidence.

#######################################
# has_open_pr Check 1: Open PRs with commits referencing this issue.
#
# The source of truth for "this PR solves this issue" is the commit messages,
# not the PR body. PR bodies are written at creation time (often from templates)
# and may mention issues for context without solving them. Commit messages are
# attached to actual code changes.
#
# GitHub auto-close works from commit messages on merge to default branch, so
# moving closing keywords from PR body to commits changes nothing for auto-close
# but eliminates false-positive dedup blocks.
#
# Args: $1 = issue number, $2 = repo slug
# Returns: exit 0 if an open PR matches (prints reason), exit 1 if no match
#######################################
_has_open_pr_check_open_commits() {
	local issue_number="$1"
	local repo_slug="$2"

	local open_pr_json open_pr_count
	open_pr_json=$(gh pr list --repo "$repo_slug" --state open \
		--json number,title,commits --limit 10 2>/dev/null) || open_pr_json="[]"
	open_pr_count=$(printf '%s' "$open_pr_json" | jq 'length' 2>/dev/null) || open_pr_count=0
	[[ "$open_pr_count" =~ ^[0-9]+$ ]] || open_pr_count=0
	[[ "$open_pr_count" -eq 0 ]] && return 1

	# Match: closing keyword + #NNN in commit messages, or GH#NNN/#NNN in PR title
	local close_pattern="(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]+([a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+)?#${issue_number}([^[:alnum:]_]|$)"
	local title_pattern="(GH#${issue_number}|#${issue_number})([^[:alnum:]_]|$)"

	local match_pr
	match_pr=$(printf '%s' "$open_pr_json" | jq -r --arg cp "$close_pattern" --arg tp "$title_pattern" \
		'[.[] | select(
			(.title // "" | test($tp)) or
			((.commits // [])[] | .messageHeadline // "" | test($cp; "i"))
		)] | .[0].number // empty' 2>/dev/null) || match_pr=""
	if [[ -n "$match_pr" ]]; then
		printf 'open PR #%s has commits targeting issue #%s\n' "$match_pr" "$issue_number"
		return 0
	fi
	return 1
}

#######################################
# has_open_pr Check 1b: OPEN PRs with closing-keyword in body (t2085).
#
# Mirrors Check 2 but scans --state open. Catches the standard framework
# convention where `full-loop-helper.sh commit-and-pr` writes
# `Resolves #NNN` into the PR body — Check 1's commit-subject matcher
# does NOT see this because the framework convention does not put
# closing keywords in commit subjects.
#
# Without this check, every routine implementation PR was invisible to
# `has_open_pr`, which left Layer 4 dedup blind to in-flight work and
# caused the marcusquinn-vs-alex-solovyev cross-runner duplicate-dispatch
# race observed on issue #18779 → PR #18906 (a duplicate worker was
# dispatched after PR #18906 was already open and waiting for review).
#
# Fetches up to 20 candidate PRs in a single call and filters locally
# with jq regex to avoid two failure modes from the prior --limit 1
# approach: (a) a false-positive first result causing the real match to
# be missed, and (b) unnecessary extra calls per keyword. The simpler
# "#NNN in:body" query lets GitHub's full-text search find candidates;
# the closing-keyword regex post-filter eliminates false positives such
# as version strings ("v3.5.670" matching issue #670).
# GH#19140 (review-followup on PR #18915).
#
# Args: $1 = issue number, $2 = repo slug
# Returns: exit 0 if an open PR closes this issue (prints reason), exit 1 if none
#######################################
_has_open_pr_check_open_body_keyword() {
	local issue_number="$1"
	local repo_slug="$2"

	local pr_json match_pr
	# Fetch up to 20 open PRs mentioning the issue in the body; body is
	# included in this single request to avoid separate gh pr view calls.
	pr_json=$(gh pr list --repo "$repo_slug" --state open \
		--search "#${issue_number} in:body" --limit 20 \
		--json number,body 2>/dev/null) || pr_json="[]"

	# Match: closing keyword + optional whitespace + #NNN or owner/repo#NNN
	# followed by a non-word char or end-of-string (GH#18641 semantics).
	local close_pattern
	close_pattern="(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]+([a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+)?#${issue_number}([^[:alnum:]_]|$)"

	match_pr=$(printf '%s' "$pr_json" | jq -r --arg pattern "$close_pattern" \
		'[.[] | select(.body // "" | test($pattern; "i"))] | .[0].number // empty' \
		2>/dev/null) || match_pr=""

	if [[ -n "$match_pr" ]]; then
		printf 'open PR #%s closes issue #%s via keyword in body\n' "$match_pr" "$issue_number"
		return 0
	fi
	return 1
}

#######################################
# has_open_pr Check 2: Merged PRs with closing-keyword in body.
#
# Fetches up to 20 candidate PRs in a single call and filters locally
# with jq regex, matching the same approach as Check 1b (GH#19140).
# Avoids the --limit 1 correctness bug where a false-positive first
# result from GitHub full-text search would mask the real matching PR.
# The "#NNN in:body" query finds candidates; the closing-keyword regex
# post-filter eliminates false positives (e.g. version strings like
# "v3.5.670" matching issue #670).
#
# Args: $1 = issue number, $2 = repo slug
# Returns: exit 0 if a merged PR closes this issue (prints reason), exit 1 if none
#######################################
_has_open_pr_check_merged_keywords() {
	local issue_number="$1"
	local repo_slug="$2"

	local pr_json match_pr
	# Fetch up to 20 merged PRs mentioning the issue in the body; body is
	# included in this single request to avoid separate gh pr view calls.
	pr_json=$(gh pr list --repo "$repo_slug" --state merged \
		--search "#${issue_number} in:body" --limit 20 \
		--json number,body 2>/dev/null) || pr_json="[]"

	# Match: closing keyword + optional whitespace + #NNN or owner/repo#NNN
	# followed by a non-word char or end-of-string (GH#18641 semantics).
	local close_pattern
	close_pattern="(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]+([a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+)?#${issue_number}([^[:alnum:]_]|$)"

	match_pr=$(printf '%s' "$pr_json" | jq -r --arg pattern "$close_pattern" \
		'[.[] | select(.body // "" | test($pattern; "i"))] | .[0].number // empty' \
		2>/dev/null) || match_pr=""

	if [[ -n "$match_pr" ]]; then
		printf 'merged PR #%s references issue #%s via keyword\n' "$match_pr" "$issue_number"
		return 0
	fi
	return 1
}

#######################################
# has_open_pr Check 3: Task-ID title match on merged PRs.
#
# GH#18041 (t1957): When a merged PR matches by task ID, verify it actually
# targets the same issue. A task ID collision (counter reset, fabricated ID)
# produces a merged PR for a *different* issue — blocking dispatch forever.
#
# GH#18641 (planning-only awareness): The framework convention uses
# `For #NNN` / `Ref #NNN` in planning-only PR bodies (briefs, TODO entries,
# research docs) so the brief PR does NOT auto-close the real implementation
# issue. The previous bare `#NNN` body-reference check treated those as
# dispatch blockers, creating a deadlock: every brief PR permanently
# blocked dispatch on its own follow-up implementation issue.
#
# Semantic: a merged PR whose title matches the task ID blocks dispatch ONLY
# if the body contains a closing-keyword reference to the specific issue
# number (the same pattern used by Check 2 and by GitHub's own auto-close
# logic). Planning references (`For #`, `Ref #`) and unrelated-issue
# collisions both fall through to "allow dispatch".
#
# Args: $1 = issue number, $2 = repo slug, $3 = issue title
# Returns: exit 0 if a merged PR closes this issue (prints reason), exit 1 otherwise
#######################################
_has_open_pr_check_task_id_title() {
	local issue_number="$1"
	local repo_slug="$2"
	local issue_title="$3"

	local task_id
	task_id=$(printf '%s' "$issue_title" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1 || true)
	[[ -z "$task_id" ]] && return 1

	local query pr_json pr_count pr_number
	query="${task_id} in:title"
	# Fetch number+body in one request to avoid a separate gh pr view call (GH#19124)
	pr_json=$(gh pr list --repo "$repo_slug" --state merged --search "$query" --limit 1 --json number,body 2>/dev/null) || pr_json="[]"
	pr_count=$(printf '%s' "$pr_json" | jq 'length' 2>/dev/null) || pr_count=0
	[[ "$pr_count" =~ ^[0-9]+$ ]] || pr_count=0
	[[ "$pr_count" -eq 0 ]] && return 1

	pr_number=$(printf '%s' "$pr_json" | jq -r '.[0].number // empty' 2>/dev/null)
	if [[ -z "$pr_number" ]]; then
		printf 'merged PR found by task id %s in title\n' "$task_id"
		return 0
	fi

	# Use the body already fetched in the initial gh pr list request and verify
	# it contains a closing-keyword reference to OUR specific issue number.
	# This mirrors the pattern in Check 2 and is the single source of truth for
	# "this PR closed this issue": if GitHub would auto-close it, we block;
	# otherwise we allow dispatch.
	local merged_pr_body
	merged_pr_body=$(printf '%s' "$pr_json" | jq -r '.[0].body // empty' 2>/dev/null)
	local close_pattern_check3="(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]+([a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+)?#${issue_number}([^[:alnum:]_]|$)"
	if printf '%s' "$merged_pr_body" | grep -iqE "$close_pattern_check3"; then
		printf 'merged PR #%s found by task id %s in title\n' "$pr_number" "$task_id"
		return 0
	fi

	# The merged PR has the same task ID but does NOT close issue
	# #${issue_number} via a closing keyword. Two valid cases fall
	# through here: (a) task-ID collision (different issue), and
	# (b) planning-only brief (For #NNN / Ref #NNN body reference).
	# Both cases allow dispatch — the real implementation is not done.
	printf 'NO_CLOSE_REF: merged PR #%s has task id %s but does not close issue #%s via closing keyword — allowing dispatch\n' \
		"$pr_number" "$task_id" "$issue_number" >&2
	return 1
}

#######################################
# Check whether an issue already has merged PR evidence.
#
# IMPORTANT: This function returns exit 0 for BOTH open and merged PRs
# that reference the issue. This is correct for dispatch dedup (any PR
# blocks re-dispatch), but callers that close issues MUST independently
# verify mergedAt before acting — an open PR means work in progress,
# not work complete. See GH#17871 for the bug this caused.
#
# Args:
#   $1 = issue number
#   $2 = repo slug (owner/repo)
#   $3 = issue title (optional; used for task-id fallback)
# Returns:
#   exit 0 if PR evidence exists — open OR merged (do NOT dispatch)
#   exit 1 if no PR evidence (safe to dispatch)
# Outputs:
#   single-line reason when evidence is found
# CALLERS: For issue closing, verify mergedAt after this returns 0.
#######################################
has_open_pr() {
	local issue_number="$1"
	local repo_slug="$2"
	local issue_title="${3:-}"

	if [[ ! "$issue_number" =~ ^[0-9]+$ ]] || [[ -z "$repo_slug" ]]; then
		return 1
	fi

	# Check 1: open PRs whose commits reference this issue.
	_has_open_pr_check_open_commits "$issue_number" "$repo_slug" && return 0

	# Check 1b (t2085): open PRs with closing-keyword in body. Required because
	# the framework convention writes `Resolves #NNN` in the PR body, not in
	# commit subjects — so Check 1's commit-subject matcher misses every
	# routine implementation PR. Without this, Layer 4 dedup is blind to
	# in-flight work and produces cross-runner duplicate dispatch (the
	# marcusquinn-vs-alex-solovyev race on issue #18779 → PR #18906).
	_has_open_pr_check_open_body_keyword "$issue_number" "$repo_slug" && return 0

	# Check 2: merged PRs with closing-keyword in body.
	_has_open_pr_check_merged_keywords "$issue_number" "$repo_slug" && return 0

	# Check 3: task-ID title match on merged PRs (planning-aware).
	_has_open_pr_check_task_id_title "$issue_number" "$repo_slug" "$issue_title" && return 0

	return 1
}
