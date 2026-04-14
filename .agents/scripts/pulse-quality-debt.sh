#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-quality-debt.sh — Quality-debt PR lifecycle — worktree creation, stale PR closure, enrichment worker dispatch.
#
# Extracted from pulse-wrapper.sh in Phase 10 (FINAL) of the phased
# decomposition (parent: GH#18356, plan: todo/plans/pulse-wrapper-decomposition.md §6).
#
# This is the final extraction. After Phase 10 merges, pulse-wrapper.sh
# drops below the 2,000-line simplification gate.
#
# Functions in this module (in source order):
#   - create_quality_debt_worktree
#   - close_stale_quality_debt_prs
#   - _enrichment_resolve_model        (private helper)
#   - _enrichment_resolve_repo_path    (private helper)
#   - _enrichment_fetch_issue_data     (private helper)
#   - _enrichment_build_prompt         (private helper)
#   - _enrichment_run_worker           (private helper)
#   - dispatch_enrichment_workers

[[ -n "${_PULSE_QUALITY_DEBT_LOADED:-}" ]] && return 0
_PULSE_QUALITY_DEBT_LOADED=1

#######################################
# Create a pre-isolated worktree for a quality-debt worker
#
# Generates a branch name from the issue number + title slug, creates the
# worktree under the same parent directory as the canonical repo, and prints
# the worktree path to stdout. Idempotent — reuses an existing worktree if
# the branch already exists.
#
# Arguments:
#   $1 - canonical repo path
#   $2 - issue number
#   $3 - issue title (used for branch slug)
#
# Outputs: worktree path (stdout)
# Exit codes:
#   0 - worktree path printed to stdout
#   1 - failed to create worktree
#######################################
create_quality_debt_worktree() {
	local repo_path="$1"
	local issue_number="$2"
	local issue_title="$3"

	local qd_branch_slug qd_branch qd_wt_path
	qd_branch_slug=$(printf '%s' "$issue_title" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | cut -c1-30)
	qd_branch="bugfix/qd-${issue_number}-${qd_branch_slug}"

	# Check if worktree already exists for this branch
	qd_wt_path=$(git -C "$repo_path" worktree list --porcelain |
		grep -B2 "branch refs/heads/${qd_branch}$" |
		grep "^worktree " | cut -d' ' -f2- 2>/dev/null || true)

	if [[ -z "$qd_wt_path" ]]; then
		local repo_name parent_dir qd_wt_slug
		repo_name=$(basename "$repo_path")
		parent_dir=$(dirname "$repo_path")
		qd_wt_slug=$(printf '%s' "$qd_branch" | tr '/' '-' | tr '[:upper:]' '[:lower:]')
		qd_wt_path="${parent_dir}/${repo_name}-${qd_wt_slug}"
		git -C "$repo_path" worktree add -b "$qd_branch" "$qd_wt_path" 2>/dev/null || {
			echo "[create_quality_debt_worktree] Failed to create worktree for #${issue_number}" >>"${LOGFILE:-/dev/null}"
			return 1
		}
	fi

	if [[ -z "$qd_wt_path" || ! -d "$qd_wt_path" ]]; then
		return 1
	fi

	printf '%s\n' "$qd_wt_path"
	return 0
}

#######################################
# Close stale quality-debt PRs that have been CONFLICTING for 24+ hours
#
# Arguments:
#   $1 - repo slug (owner/repo)
#
# Exit code: always 0
#######################################
close_stale_quality_debt_prs() {
	local repo_slug="$1"
	local cutoff_epoch
	cutoff_epoch=$(date -v-24H +%s 2>/dev/null || date -d '24 hours ago' +%s 2>/dev/null || echo 0)

	local pr_json
	pr_json=$(gh pr list --repo "$repo_slug" --state open \
		--json number,title,labels,mergeable,updatedAt \
		--jq '[.[] | select(.mergeable == "CONFLICTING") | select(.labels[]?.name == "quality-debt" or (.title | test("quality.debt|fix:.*batch|fix:.*harden"; "i")))]' \
		2>/dev/null) || pr_json="[]"

	local pr_count
	pr_count=$(printf '%s' "$pr_json" | jq 'length' 2>/dev/null || echo 0)
	[[ "$pr_count" =~ ^[0-9]+$ ]] || pr_count=0
	[[ "$pr_count" -gt 0 ]] || return 0

	local i
	for i in $(seq 0 $((pr_count - 1))); do
		local pr_num pr_updated_at pr_epoch
		pr_num=$(printf '%s' "$pr_json" | jq -r ".[$i].number" 2>/dev/null) || continue
		pr_updated_at=$(printf '%s' "$pr_json" | jq -r ".[$i].updatedAt" 2>/dev/null) || continue
		# GH#17699: TZ=UTC required — macOS date interprets input as local time
		pr_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$pr_updated_at" +%s 2>/dev/null ||
			date -d "$pr_updated_at" +%s 2>/dev/null || echo 0)

		if [[ "$pr_epoch" -lt "$cutoff_epoch" ]]; then
			gh pr close "$pr_num" --repo "$repo_slug" \
				-c "Closing — this PR has merge conflicts and touches too many files (blast radius issue, see t1422). The underlying fixes will be re-created as smaller PRs (max 5 files each) to prevent conflict cascades." \
				2>/dev/null || true
			# Relabel linked issue status:available
			local issue_num
			issue_num=$(gh pr view "$pr_num" --repo "$repo_slug" --json body \
				--jq '.body | match("(?i)(closes|fixes|resolves)[[:space:]]+#([0-9]+)").captures[1].string' \
				2>/dev/null || true)
			if [[ -n "$issue_num" ]]; then
				# t2033: atomic transition — clears all sibling status labels,
				# not just status:in-review.
				set_issue_status "$issue_num" "$repo_slug" "available" 2>/dev/null || true
			fi
		fi
	done
	return 0
}

#######################################
# Resolve the best available enrichment model (opus preferred, sonnet fallback)
#
# Outputs: model identifier string (stdout) if resolved
# Exit codes:
#   0 - model resolved and printed to stdout
#   1 - no thinking-tier model available
#######################################
_enrichment_resolve_model() {
	local resolved_model=""
	resolved_model=$("$MODEL_AVAILABILITY_HELPER" resolve opus || echo "")
	if [[ -z "$resolved_model" ]]; then
		resolved_model=$("$MODEL_AVAILABILITY_HELPER" resolve sonnet || echo "")
	fi
	if [[ -z "$resolved_model" ]]; then
		echo "[pulse-wrapper] dispatch_enrichment_workers: no thinking-tier model available — skipping" >>"$LOGFILE"
		return 1
	fi
	printf '%s\n' "$resolved_model"
	return 0
}

#######################################
# Resolve the local filesystem path for a repo slug
#
# Arguments:
#   $1 - repo slug (owner/repo)
#   $2 - repos.json path (optional; defaults to $REPOS_JSON or ~/.config/aidevops/repos.json)
#
# Outputs: absolute repo path (stdout) if found
# Exit codes:
#   0 - path resolved and printed to stdout
#   1 - slug not found or directory does not exist
#######################################
_enrichment_resolve_repo_path() {
	local repo_slug="$1"
	local repos_json="${2:-${REPOS_JSON:-$HOME/.config/aidevops/repos.json}}"

	local repo_path
	repo_path=$(jq -r --arg s "$repo_slug" \
		'.initialized_repos[]? | select(.slug == $s) | .path' \
		"$repos_json" 2>/dev/null || echo "")
	repo_path="${repo_path/#\~/$HOME}"
	[[ -n "$repo_path" && -d "$repo_path" ]] || return 1

	printf '%s\n' "$repo_path"
	return 0
}

#######################################
# Fetch issue body, title, and relevant failure-context comments
#
# Arguments:
#   $1 - issue number
#   $2 - repo slug (owner/repo)
#
# Outputs: JSON object {title, body, comments} (stdout)
# Exit codes:
#   0 - data fetched (partial data is acceptable; fields may be empty strings)
#######################################
_enrichment_fetch_issue_data() {
	local issue_number="$1"
	local repo_slug="$2"

	local issue_json issue_body issue_title issue_comments
	issue_json=$(gh issue view "$issue_number" --repo "$repo_slug" \
		--json title,body 2>/dev/null) || issue_json="{}"
	issue_title=$(printf '%s' "$issue_json" | jq -r '.title // ""')
	issue_body=$(printf '%s' "$issue_json" | jq -r '.body // ""')

	# Get kill/dispatch comments for failure context
	issue_comments=$(gh api "repos/${repo_slug}/issues/${issue_number}/comments" \
		--jq '[.[] | select(.body | test("CLAIM|kill|premature|BLOCKED|worker_failed|Dispatching")) | {author: .user.login, body: .body, created: .created_at}] | last(3) // []' \
		2>/dev/null) || issue_comments="[]"

	jq -n \
		--arg title "$issue_title" \
		--arg body "$issue_body" \
		--argjson comments "$issue_comments" \
		'{title: $title, body: $body, comments: $comments}'
	return 0
}

#######################################
# Build the enrichment analysis prompt and write it to a temp file
#
# Arguments:
#   $1 - issue number
#   $2 - issue title
#   $3 - issue body
#   $4 - issue comments (JSON array string)
#   $5 - repo slug (owner/repo)
#
# Outputs: path to the temporary prompt file (stdout)
# Exit codes:
#   0 - prompt file created and path printed to stdout
#   1 - failed to create temp file
#######################################
_enrichment_build_prompt() {
	local issue_number="$1"
	local issue_title="$2"
	local issue_body="$3"
	local issue_comments="$4"
	local repo_slug="$5"

	local prompt_file
	prompt_file=$(mktemp) || return 1

	cat >"$prompt_file" <<ENRICHMENT_PROMPT_EOF
You are a thinking-tier analyst. A worker attempted to implement issue #${issue_number} but failed.
Your job: analyze the issue and codebase, then edit the issue body to add concrete implementation guidance.

## Issue Title
${issue_title}

## Current Issue Body
${issue_body}

## Recent Comments (failure context)
${issue_comments}

## Instructions

1. Read the issue body to understand the task
2. Search the codebase (use Bash with rg/git ls-files, Read, Grep) to identify:
   - Exact file paths that need modification
   - Reference patterns in similar existing code
   - The verification command to confirm completion
3. Edit the issue body on GitHub using: gh issue edit ${issue_number} --repo ${repo_slug} --body "\$NEW_BODY"
   - Preserve the existing body content
   - Append a new section:

## Worker Guidance

**Files to modify:**
- EDIT: path/to/file.ext:LINE_RANGE — description
- NEW: path/to/new-file.ext — model on path/to/reference.ext

**Reference pattern:** Follow the pattern at path/to/similar.ext:LINES

**What the previous worker likely struggled with:** (your analysis)

**Verification:** command to verify completion

4. Keep analysis focused — spend at most 5 minutes. If the task is genuinely ambiguous, say so in the guidance rather than guessing.
5. Do NOT implement the solution. Only analyze and document guidance.
ENRICHMENT_PROMPT_EOF

	printf '%s\n' "$prompt_file"
	return 0
}

#######################################
# Run the enrichment worker for a single issue and check whether it succeeded
#
# Runs a thinking-tier headless worker using the provided prompt file, then
# verifies that "Worker Guidance" was added to the issue body on GitHub.
# Cleans up the prompt file and worker output regardless of result.
#
# Arguments:
#   $1 - prompt file path (deleted by this function on completion)
#   $2 - issue number
#   $3 - repo slug (owner/repo)
#   $4 - repo path (working directory for the worker)
#   $5 - resolved model identifier
#
# Exit codes:
#   0 - enrichment succeeded (Worker Guidance section found in issue body)
#   1 - enrichment ran but no Worker Guidance was added
#######################################
_enrichment_run_worker() {
	local prompt_file="$1"
	local issue_number="$2"
	local repo_slug="$3"
	local repo_path="$4"
	local resolved_model="$5"

	_save_cleanup_scope
	trap '_run_cleanups' RETURN

	local enrichment_output
	enrichment_output=$(mktemp)
	push_cleanup "rm -f '${enrichment_output}'"
	push_cleanup "rm -f '${prompt_file}'"

	# shellcheck disable=SC2086
	"$HEADLESS_RUNTIME_HELPER" run \
		--role worker \
		--session-key "enrichment-${issue_number}" \
		--dir "$repo_path" \
		--model "$resolved_model" \
		--title "Enrichment analysis: Issue #${issue_number}" \
		--prompt-file "$prompt_file" </dev/null >"$enrichment_output" 2>&1

	local enrichment_exit=$?

	# Check if enrichment succeeded (issue body was edited)
	local post_body
	post_body=$(gh issue view "$issue_number" --repo "$repo_slug" \
		--json body --jq '.body // ""' 2>/dev/null) || post_body=""

	if [[ "$post_body" == *"Worker Guidance"* ]]; then
		echo "[pulse-wrapper] Enrichment: successfully added Worker Guidance to #${issue_number} in ${repo_slug}" >>"$LOGFILE"
		return 0
	else
		echo "[pulse-wrapper] Enrichment: worker ran (exit=${enrichment_exit}) but no Worker Guidance found in #${issue_number} body (${#post_body} chars)" >>"$LOGFILE"
		return 1
	fi
}

#######################################
# Dispatch enrichment workers for issues that failed and need implementation guidance
#
# Reads the fast-fail state to find issues with enrichment_needed=true, resolves
# a thinking-tier model, then dispatches a headless worker per issue to add a
# "Worker Guidance" section to the issue body on GitHub.
#
# Arguments:
#   $1 - available worker slots (integer)
#
# Outputs: updated available slot count (stdout)
# Exit code: always 0
#######################################
dispatch_enrichment_workers() {
	local available="$1"
	local enrichment_count=0

	[[ "$available" =~ ^[0-9]+$ ]] || available=0
	[[ "$available" -gt 0 ]] || {
		printf '%d\n' "$available"
		return 0
	}

	# Read fast-fail state for issues needing enrichment
	local state
	state=$(_ff_load)
	[[ -n "$state" && "$state" != "{}" && "$state" != "null" ]] || {
		printf '%d\n' "$available"
		return 0
	}

	# Resolve thinking-tier model (opus preferred, sonnet fallback)
	local resolved_model
	resolved_model=$(_enrichment_resolve_model) || {
		printf '%d\n' "$available"
		return 0
	}

	# Extract keys with enrichment_needed=true
	local enrichment_keys
	enrichment_keys=$(printf '%s' "$state" | jq -r 'to_entries[] | select(.value.enrichment_needed == true) | .key' 2>/dev/null) || enrichment_keys=""

	[[ -n "$enrichment_keys" ]] || {
		printf '%d\n' "$available"
		return 0
	}

	local repos_json="${REPOS_JSON:-$HOME/.config/aidevops/repos.json}"
	local enriched_total=0

	while IFS= read -r ff_key; do
		[[ -n "$ff_key" ]] || continue
		[[ "$enrichment_count" -lt "$ENRICHMENT_MAX_PER_CYCLE" ]] || break
		[[ "$available" -gt 0 ]] || break
		[[ -f "$STOP_FLAG" ]] && break

		# Parse key format: "issue_number:repo_slug"
		local issue_number repo_slug
		issue_number="${ff_key%%:*}"
		repo_slug="${ff_key#*:}"
		[[ "$issue_number" =~ ^[0-9]+$ ]] || continue
		[[ -n "$repo_slug" ]] || continue

		# Resolve repo path
		local repo_path
		repo_path=$(_enrichment_resolve_repo_path "$repo_slug" "$repos_json") || continue

		echo "[pulse-wrapper] Enrichment: analyzing #${issue_number} in ${repo_slug} after worker failure" >>"$LOGFILE"

		# Fetch issue data (body, title, failure-context comments) as JSON
		local issue_data issue_title issue_body issue_comments
		issue_data=$(_enrichment_fetch_issue_data "$issue_number" "$repo_slug")
		issue_title=$(printf '%s' "$issue_data" | jq -r '.title // ""')
		issue_body=$(printf '%s' "$issue_data" | jq -r '.body // ""')
		issue_comments=$(printf '%s' "$issue_data" | jq -r '.comments // []')

		# Build enrichment prompt file
		local prompt_file
		prompt_file=$(_enrichment_build_prompt \
			"$issue_number" "$issue_title" "$issue_body" "$issue_comments" "$repo_slug") || continue

		# Run enrichment worker; prompt_file is deleted inside helper
		if _enrichment_run_worker \
			"$prompt_file" "$issue_number" "$repo_slug" "$repo_path" "$resolved_model"; then
			enriched_total=$((enriched_total + 1))
		fi

		# Mark enrichment complete in fast-fail state (regardless of success —
		# don't retry enrichment, let normal escalation handle persistent failures)
		_ff_with_lock _ff_mark_enrichment_done "$issue_number" "$repo_slug" || true

		enrichment_count=$((enrichment_count + 1))
		available=$((available - 1))
	done <<<"$enrichment_keys"

	if [[ "$enrichment_count" -gt 0 ]]; then
		echo "[pulse-wrapper] dispatch_enrichment_workers: processed ${enrichment_count} issues (${enriched_total} enriched), ${available} slots remaining" >>"$LOGFILE"
	fi

	printf '%d\n' "$available"
	return 0
}
