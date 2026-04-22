#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Intentionally using /bin/bash (not /usr/bin/env bash) for headless compatibility.
# Some MCP/headless runners provide a stripped PATH where env cannot resolve bash.
# Keep this exception aligned with issue #2610 and t135.14 standardization context.
# shellcheck disable=SC2155
# =============================================================================
# aidevops Issue Sync — Relationships & Backfill (GH#19502)
# =============================================================================
# Extracted from issue-sync-helper.sh to reduce the main file below the 2000-line
# gate. Contains two cohesive functional areas:
#
#   1. Relationships (t1889) — sync blocked-by/blocks and subtask hierarchy to
#      GitHub's native issue relationships via GraphQL mutations.
#   2. Backfill sub-issues (t2114, GH#19093) — detect and link parent-child
#      issue relationships from GitHub state alone (title + body), without
#      requiring a TODO.md entry or brief file.
#
# Usage: source "${SCRIPT_DIR}/issue-sync-relationships.sh"
#
# Dependencies (all available when sourced from issue-sync-helper.sh):
#   - shared-constants.sh (print_error, print_info)
#   - issue-sync-lib.sh (parse_task_line, resolve_task_gh_number,
#     detect_parent_task_id, resolve_gh_node_id, strip_code_fences, _escape_ere)
#   - issue-sync-helper.sh globals: log_verbose, _init_cmd, DRY_RUN, VERBOSE
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced — would affect caller)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard — prevents double-loading when sourced from multiple paths.
[[ -n "${_ISSUE_SYNC_RELATIONSHIPS_LOADED:-}" ]] && return 0
_ISSUE_SYNC_RELATIONSHIPS_LOADED=1

# =============================================================================
# Relationships — GitHub Issue Dependencies & Hierarchy (t1889)
# =============================================================================
# Syncs TODO.md blocked-by:/blocks: and subtask hierarchy to GitHub's native
# issue relationships via GraphQL mutations.

# Node ID cache: avoids repeated API calls for the same issue number.
# Uses a temp file (bash 3.2 compatible — no associative arrays).
# Format: one "number=node_id" per line. Populated by _cached_node_id().
_NODE_ID_CACHE_FILE=""

# Rate-limited flag file: written by _cached_node_id when GraphQL is exhausted
# AND the REST fallback also fails. Uses a file (not a bash variable) so that
# the signal survives bash subshell boundaries — callers invoke _cached_node_id
# via $() which spawns a subshell, so bash variable writes inside would be lost.
# Callers check via _node_id_was_rate_limited. Reset to empty at each call.
_NODE_ID_RATE_LIMITED_FILE=""

_init_node_id_cache() {
	if [[ -z "$_NODE_ID_CACHE_FILE" ]]; then
		_NODE_ID_CACHE_FILE=$(mktemp "${TMPDIR:-/tmp}/aidevops-node-cache.XXXXXX")
		_NODE_ID_RATE_LIMITED_FILE=$(mktemp "${TMPDIR:-/tmp}/aidevops-ratelimited.XXXXXX")
		# Chain onto any existing EXIT trap rather than replacing it.
		local _prev_trap
		_prev_trap=$(trap -p EXIT | sed -E "s/^trap -- '(.*)' EXIT$/\1/")
		# shellcheck disable=SC2064
		trap "rm -f '$_NODE_ID_CACHE_FILE' '$_NODE_ID_RATE_LIMITED_FILE'${_prev_trap:+; $_prev_trap}" EXIT
	fi
	return 0
}

# Return 0 (true) if the most recent _cached_node_id call was rate-limited.
# Reads the flag file written by the subshell — bash variables set inside $()
# are discarded when the subshell exits, but file writes persist.
_node_id_was_rate_limited() {
	[[ -n "${_NODE_ID_RATE_LIMITED_FILE:-}" ]] && \
		[[ "$(cat "$_NODE_ID_RATE_LIMITED_FILE" 2>/dev/null)" == "1" ]]
	return $?
}

_cached_node_id() {
	local num="$1" repo="$2"
	[[ -z "$num" ]] && return 0
	_init_node_id_cache
	# Reset the rate-limited flag for this resolution. Runs inside the subshell
	# spawned by callers' $() — the file truncation IS visible to the parent.
	[[ -n "$_NODE_ID_RATE_LIMITED_FILE" ]] && : >"$_NODE_ID_RATE_LIMITED_FILE"

	# Check cache file
	local cached
	cached=$(grep -m1 "^${num}=" "$_NODE_ID_CACHE_FILE" 2>/dev/null | cut -d= -f2- || echo "")
	if [[ -n "$cached" ]]; then
		echo "$cached"
		return 0
	fi

	local nid
	nid=$(resolve_gh_node_id "$num" "$repo")
	if [[ -n "$nid" ]]; then
		echo "${num}=${nid}" >>"$_NODE_ID_CACHE_FILE"
		echo "$nid"
		return 0
	fi

	# GraphQL returned empty. If rate-limited, try REST path (t2739).
	# REST: GET /repos/{owner}/{repo}/issues/{number} → .node_id
	# Uses the same core-pool 5000/hr budget that the t2574 write-path fallbacks use.
	if _gh_should_fallback_to_rest; then
		local rest_nid
		rest_nid=$(gh api "/repos/${repo}/issues/${num}" --jq '.node_id' 2>/dev/null || echo "")
		if [[ -n "$rest_nid" ]]; then
			echo "${num}=${rest_nid}" >>"$_NODE_ID_CACHE_FILE"
			echo "$rest_nid"
			return 0
		fi
		# Both GraphQL and REST failed — write flag so callers can emit RATE_LIMITED.
		[[ -n "$_NODE_ID_RATE_LIMITED_FILE" ]] && echo "1" >"$_NODE_ID_RATE_LIMITED_FILE"
	fi
	return 0
}

# Add a blocked-by relationship between two issues.
# issueId = the blocked issue, blockingIssueId = the blocker.
# Suppresses "already taken" errors (idempotent semantics).
# Arguments:
#   $1 - blocked_node_id (the issue that IS blocked)
#   $2 - blocking_node_id (the issue that BLOCKS)
# Returns: 0=success/already-exists, 1=error
_gh_add_blocked_by() {
	local blocked_id="$1" blocking_id="$2"
	local result
	result=$(gh api graphql -f query='
mutation($blocked:ID!,$blocking:ID!) {
  addBlockedBy(input: {issueId:$blocked, blockingIssueId:$blocking}) {
    issue { number }
  }
}' -f blocked="$blocked_id" -f blocking="$blocking_id" 2>&1)

	# Success or already-exists are both fine
	if echo "$result" | grep -q '"number"'; then
		return 0
	fi
	if echo "$result" | grep -qi 'already been taken'; then
		log_verbose "  blocked-by relationship already exists"
		return 0
	fi
	log_verbose "  addBlockedBy error: ${result:0:200}"
	return 1
}

# Add a sub-issue (parent-child) relationship.
# Suppresses "duplicate sub-issues" and "only have one parent" errors.
# Arguments:
#   $1 - parent_node_id
#   $2 - child_node_id
# Returns: 0=success/already-exists, 1=error
_gh_add_sub_issue() {
	local parent_id="$1" child_id="$2"
	local result
	result=$(gh api graphql -f query='
mutation($parent:ID!,$child:ID!) {
  addSubIssue(input: {issueId:$parent, subIssueId:$child}) {
    issue { number }
  }
}' -f parent="$parent_id" -f child="$child_id" 2>&1)

	if echo "$result" | grep -q '"number"'; then
		return 0
	fi
	if echo "$result" | grep -qi 'duplicate sub-issues\|only have one parent'; then
		log_verbose "  sub-issue relationship already exists"
		return 0
	fi
	log_verbose "  addSubIssue error: ${result:0:200}"
	return 1
}

# Sync blocked-by and blocks relationships for a single task.
# Parses the task line for blocked-by: and blocks: fields, resolves each
# referenced task to a GitHub node ID, and creates the relationship.
# Arguments:
#   $1 - task_id
#   $2 - todo_file path
#   $3 - repo slug
# Returns: number of relationships set (via stdout "RELS:N")
_sync_blocked_by_for_task() {
	local task_id="$1" todo_file="$2" repo="$3"
	local task_id_ere
	task_id_ere=$(_escape_ere "$task_id")
	local task_line
	task_line=$(strip_code_fences <"$todo_file" | grep -E "^\s*- \[.\] ${task_id_ere} " | head -1 || echo "")
	[[ -z "$task_line" ]] && return 0

	local parsed
	parsed=$(parse_task_line "$task_line")
	local blocked_by="" blocks=""
	while IFS='=' read -r key value; do
		case "$key" in
		blocked_by) blocked_by="$value" ;;
		blocks) blocks="$value" ;;
		esac
	done <<<"$parsed"

	[[ -z "$blocked_by" && -z "$blocks" ]] && return 0

	# Resolve this task's node ID
	local this_gh_num
	this_gh_num=$(resolve_task_gh_number "$task_id" "$todo_file")
	[[ -z "$this_gh_num" ]] && {
		log_verbose "$task_id: no ref:GH# — skipping relationships"
		return 0
	}
	local this_node_id
	this_node_id=$(_cached_node_id "$this_gh_num" "$repo")
	[[ -z "$this_node_id" ]] && {
		log_verbose "$task_id: could not resolve node ID for #$this_gh_num"
		return 0
	}

	local rels_set=0

	# Process blocked-by: this task IS blocked BY each listed task
	if [[ -n "$blocked_by" ]]; then
		local _saved_ifs="$IFS"
		IFS=','
		for dep_task_id in $blocked_by; do
			dep_task_id="${dep_task_id// /}"
			[[ -z "$dep_task_id" ]] && continue
			local dep_gh_num
			dep_gh_num=$(resolve_task_gh_number "$dep_task_id" "$todo_file")
			[[ -z "$dep_gh_num" ]] && {
				log_verbose "$task_id: blocked-by $dep_task_id has no ref:GH#"
				continue
			}
			local dep_node_id
			dep_node_id=$(_cached_node_id "$dep_gh_num" "$repo")
			[[ -z "$dep_node_id" ]] && continue

			if [[ "$DRY_RUN" == "true" ]]; then
				print_info "[DRY-RUN] Would set #$this_gh_num blocked-by #$dep_gh_num ($task_id <- $dep_task_id)"
				rels_set=$((rels_set + 1))
			elif _gh_add_blocked_by "$this_node_id" "$dep_node_id"; then
				log_verbose "$task_id (#$this_gh_num) blocked-by $dep_task_id (#$dep_gh_num) ✓"
				rels_set=$((rels_set + 1))
			fi
		done
		IFS="$_saved_ifs"
	fi

	# Process blocks: this task BLOCKS each listed task
	# Inverse of blocked-by: call addBlockedBy with roles swapped
	if [[ -n "$blocks" ]]; then
		local _saved_ifs="$IFS"
		IFS=','
		for dep_task_id in $blocks; do
			dep_task_id="${dep_task_id// /}"
			[[ -z "$dep_task_id" ]] && continue
			local dep_gh_num
			dep_gh_num=$(resolve_task_gh_number "$dep_task_id" "$todo_file")
			[[ -z "$dep_gh_num" ]] && {
				log_verbose "$task_id: blocks $dep_task_id has no ref:GH#"
				continue
			}
			local dep_node_id
			dep_node_id=$(_cached_node_id "$dep_gh_num" "$repo")
			[[ -z "$dep_node_id" ]] && continue

			if [[ "$DRY_RUN" == "true" ]]; then
				print_info "[DRY-RUN] Would set #$dep_gh_num blocked-by #$this_gh_num ($dep_task_id <- $task_id)"
				rels_set=$((rels_set + 1))
			elif _gh_add_blocked_by "$dep_node_id" "$this_node_id"; then
				log_verbose "$dep_task_id (#$dep_gh_num) blocked-by $task_id (#$this_gh_num) ✓"
				rels_set=$((rels_set + 1))
			fi
		done
		IFS="$_saved_ifs"
	fi

	echo "RELS:$rels_set"
	return 0
}

# Link a single child issue as a sub-issue of a parent issue.
# Resolves task IDs to GitHub node IDs and calls the addSubIssue mutation.
# Arguments:
#   $1 - child_task_id
#   $2 - parent_task_id
#   $3 - todo_file path
#   $4 - repo slug
# Returns: 0 if linked (or would-link in dry-run), 1 if skipped
_link_sub_issue_pair() {
	local child_id="$1" parent_id="$2" todo_file="$3" repo="$4"

	local child_gh_num
	child_gh_num=$(resolve_task_gh_number "$child_id" "$todo_file")
	[[ -z "$child_gh_num" ]] && {
		log_verbose "$child_id: no ref:GH# — skipping sub-issue"
		return 1
	}
	local parent_gh_num
	parent_gh_num=$(resolve_task_gh_number "$parent_id" "$todo_file")
	[[ -z "$parent_gh_num" ]] && {
		log_verbose "$child_id: parent $parent_id has no ref:GH# — skipping sub-issue"
		return 1
	}

	local child_node_id
	child_node_id=$(_cached_node_id "$child_gh_num" "$repo")
	[[ -z "$child_node_id" ]] && return 1
	local parent_node_id
	parent_node_id=$(_cached_node_id "$parent_gh_num" "$repo")
	[[ -z "$parent_node_id" ]] && return 1

	if [[ "$DRY_RUN" == "true" ]]; then
		print_info "[DRY-RUN] Would set #$child_gh_num as sub-issue of #$parent_gh_num ($child_id -> $parent_id)"
		return 0
	fi

	if _gh_add_sub_issue "$parent_node_id" "$child_node_id"; then
		log_verbose "$child_id (#$child_gh_num) sub-issue of $parent_id (#$parent_gh_num) ✓"
		return 0
	fi
	return 1
}

# Check if a task ID has the #parent / #parent-task / #meta tag in TODO.md.
# Arguments:
#   $1 - task_id to check
#   $2 - todo_file path
# Returns: 0 if parent-tagged, 1 otherwise
_is_parent_tagged_task() {
	local task_id="$1" todo_file="$2"
	local task_id_ere
	task_id_ere=$(_escape_ere "$task_id")

	local task_line
	task_line=$(strip_code_fences <"$todo_file" | grep -E "^\s*- \[.\] ${task_id_ere} " | head -1 || echo "")
	[[ -z "$task_line" ]] && return 1

	# Check for #parent, #parent-task, or #meta tags
	if echo "$task_line" | grep -qE '#parent\b|#parent-task\b|#meta\b'; then
		return 0
	fi
	return 1
}

# Sync parent-child (sub-issue) relationships for a task.
# Detects parent-child via two mechanisms:
#   1. Dot-notation: t1873.2 → parent t1873
#   2. blocked-by a #parent-tagged task: blocked-by:t2010 where t2010 has #parent tag
# Arguments:
#   $1 - task_id
#   $2 - todo_file path
#   $3 - repo slug
# Returns: "RELS:N" with count of relationships set
_sync_subtask_hierarchy_for_task() {
	local task_id="$1" todo_file="$2" repo="$3"
	local rels_set=0

	# Method 1: Dot-notation (t1873.2 → parent t1873)
	local dot_parent
	dot_parent=$(detect_parent_task_id "$task_id")
	if [[ -n "$dot_parent" ]]; then
		_link_sub_issue_pair "$task_id" "$dot_parent" "$todo_file" "$repo" && rels_set=$((rels_set + 1))
	fi

	# Method 2: blocked-by a #parent-tagged task
	local task_id_ere
	task_id_ere=$(_escape_ere "$task_id")
	local task_line
	task_line=$(strip_code_fences <"$todo_file" | grep -E "^\s*- \[.\] ${task_id_ere} " | head -1 || echo "")
	if [[ -n "$task_line" ]]; then
		local blocked_by=""
		local parsed
		parsed=$(parse_task_line "$task_line")
		while IFS='=' read -r key value; do
			[[ "$key" == "blocked_by" ]] && blocked_by="$value"
		done <<<"$parsed"

		if [[ -n "$blocked_by" ]]; then
			local _saved_ifs="$IFS"
			IFS=','
			for dep_task_id in $blocked_by; do
				dep_task_id="${dep_task_id// /}"
				[[ -z "$dep_task_id" ]] && continue
				# Skip if this is already the dot-notation parent (avoid duplicate)
				[[ "$dep_task_id" == "$dot_parent" ]] && continue
				# Only create sub-issue if the dependency is a parent-tagged task
				if _is_parent_tagged_task "$dep_task_id" "$todo_file"; then
					_link_sub_issue_pair "$task_id" "$dep_task_id" "$todo_file" "$repo" && rels_set=$((rels_set + 1))
				fi
			done
			IFS="$_saved_ifs"
		fi
	fi

	echo "RELS:$rels_set"
	return 0
}

# Sync all relationships for a single task (blocked-by + subtask hierarchy).
# Convenience wrapper called after push/enrich operations.
# Arguments:
#   $1 - task_id
#   $2 - todo_file path
#   $3 - repo slug
sync_relationships_for_task() {
	local task_id="$1" todo_file="$2" repo="$3"
	_sync_blocked_by_for_task "$task_id" "$todo_file" "$repo" >/dev/null 2>&1 || true
	_sync_subtask_hierarchy_for_task "$task_id" "$todo_file" "$repo" >/dev/null 2>&1 || true
	return 0
}

# Bulk relationship sync command.
# Scans TODO.md for all tasks with blocked-by:/blocks: or subtask patterns,
# resolves to GitHub node IDs, and sets relationships via GraphQL.
# Arguments:
#   $1 - optional target task_id (if empty, processes all)
cmd_relationships() {
	local target_task="${1:-}"
	_init_cmd || return 1
	local repo="$_CMD_REPO" todo_file="$_CMD_TODO"

	local tasks=()
	if [[ -n "$target_task" ]]; then
		tasks=("$target_task")
	else
		# Collect tasks with blocked-by:, blocks:, or subtask IDs (contain a dot)
		while IFS= read -r line; do
			local tid
			tid=$(echo "$line" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1 || echo "")
			[[ -z "$tid" ]] && continue
			# Include if it has dependencies or is a subtask
			local dominated=false
			echo "$line" | grep -qE 'blocked-by:|blocks:' && dominated=true
			[[ "$tid" == *"."* ]] && dominated=true
			[[ "$dominated" == "true" ]] && tasks+=("$tid")
		done < <(strip_code_fences <"$todo_file" | grep -E '^\s*- \[.\] t[0-9]+.*ref:GH#[0-9]+' || true)
	fi

	[[ ${#tasks[@]} -eq 0 ]] && {
		print_info "No tasks with relationships to sync"
		return 0
	}

	# Deduplicate (bash 3.2 compatible — no associative arrays)
	local seen_list=""
	local unique_tasks=()
	local t
	for t in "${tasks[@]}"; do
		if ! printf '%s' "$seen_list" | grep -Fxq -- "$t"; then
			unique_tasks+=("$t")
			seen_list="${seen_list}${t}"$'\n'
		fi
	done

	local total="${#unique_tasks[@]}"
	print_info "Syncing relationships for $total task(s) in $repo"

	local blocked_set=0 sub_set=0 processed=0
	for task_id in "${unique_tasks[@]}"; do
		processed=$((processed + 1))
		# Progress indicator every 25 tasks
		if [[ $((processed % 25)) -eq 0 || $processed -eq $total ]]; then
			printf "\r  Progress: %d/%d tasks..." "$processed" "$total" >&2
		fi

		local result

		# Blocked-by / blocks
		result=$(_sync_blocked_by_for_task "$task_id" "$todo_file" "$repo" 2>/dev/null || echo "RELS:0")
		local n
		n=$(echo "$result" | grep -oE 'RELS:[0-9]+' | head -1 | sed 's/RELS://' || echo "0")
		blocked_set=$((blocked_set + n))

		# Sub-issue hierarchy
		result=$(_sync_subtask_hierarchy_for_task "$task_id" "$todo_file" "$repo" 2>/dev/null || echo "RELS:0")
		n=$(echo "$result" | grep -oE 'RELS:[0-9]+' | head -1 | sed 's/RELS://' || echo "0")
		sub_set=$((sub_set + n))
	done
	[[ $total -gt 25 ]] && printf "\n" >&2

	printf "\n=== Relationships Sync ===\nBlocked-by: %d | Sub-issues: %d | Tasks processed: %d\n" \
		"$blocked_set" "$sub_set" "${#unique_tasks[@]}"
	return 0
}

# =============================================================================
# Backfill sub-issue links from GitHub state alone (t2114 — GH#19093)
# =============================================================================
# Unlike `cmd_relationships`, which is TODO-driven, and `_gh_auto_link_sub_issue`,
# which is wrapper-driven, `cmd_backfill_sub_issues` operates purely on GitHub
# state — title and body of each issue — without requiring a TODO entry or a
# brief file. It closes the "issue already exists, no TODO, wrapper bypassed"
# gap that leaves decomposition issues unlinked to their parents.
#
# Detection precedence (first match wins):
#   1. Dot-notation in title — `^(t\d+)\.\d+: ` → parent `t\1` (resolved via
#      gh search in the same repo). Used when a decomposition child was filed
#      with the t<parent>.<n> convention.
#   2. Explicit `Parent:` line in body — `Parent: tNNN` / `Parent: GH#NNN` /
#      `Parent: #NNN`. Bold-markdown (`**Parent:**`) and backtick-quoted refs
#      are accepted. Used when the filer names the parent directly.
#   3. `Blocked by: tNNN` where the referenced task carries the `parent-task`
#      label on GitHub. This is the only case where the parent-task label
#      gates the detection — the label indicates the blocker is a roadmap
#      parent, not a peer dependency.

# Resolve a top-level task ID (e.g., t1873) to its GitHub issue number by
# searching the repo. Matches only titles of the form "tNNN:" or "tNNN " —
# subtasks like "tNNN.2:" are deliberately excluded so that parent resolution
# can never return a sibling.
#
# Arguments:
#   $1 - task_id (e.g., t1873)
#   $2 - repo slug
# Echo: issue number on stdout, empty if not found
_resolve_task_id_via_gh_search() {
	local task_id="$1" repo="$2"
	[[ -z "$task_id" || -z "$repo" ]] && return 0
	# Dotted IDs (e.g. t2114.1) are the legitimate parent of a deeper child
	# like t2114.1.2. Previously the helper force-collapsed any dotted input
	# to its top-level root, which made multi-level dot-notation parent
	# resolution impossible — callers always got back t2114 instead of
	# t2114.1. We now accept dotted IDs and escape the dots in the jq regex
	# so the anchored match still rejects sibling subtasks (e.g. t2114.12).

	local matches
	# gh search is tokenised by whitespace; passing `t2114.1` still surfaces
	# the right candidates because the dot is a separator in the search
	# query. We filter strictly via jq below.
	matches=$(gh search issues "$task_id" --repo "$repo" --state all \
		--json number,title --limit 10 2>/dev/null || echo "[]")

	# Escape dots for the jq regex so `t2114.1` does not accidentally match
	# `t21141:` (where `.` would match any char in PCRE). Bash replacement
	# `\\.` resolves to a literal `\.` (single backslash + dot) in the
	# resulting string, which is what jq's test() needs to match a literal.
	local tid_escaped="${task_id//./\\.}"

	local num
	num=$(printf '%s' "$matches" | jq -r --arg tid "$tid_escaped" \
		'.[] | select(.title | test("^" + $tid + "([: ]|$)")) | .number' 2>/dev/null | head -1 || echo "")
	echo "$num"
	return 0
}

# Check whether an issue carries the `parent-task` label.
# Arguments:
#   $1 - issue number
#   $2 - repo slug
# Returns: 0 if labelled, 1 otherwise
_issue_has_parent_task_label() {
	local num="$1" repo="$2"
	[[ -z "$num" || -z "$repo" ]] && return 1

	local has
	has=$(gh issue view "$num" --repo "$repo" --json labels \
		--jq '[.labels[].name] | any(. == "parent-task")' 2>/dev/null || echo "false")
	[[ "$has" == "true" ]] && return 0
	return 1
}

# Detect a parent issue reference from an issue's title and body alone.
# No TODO.md or brief file is consulted — this is the purely-GH-driven path.
#
# Arguments:
#   $1 - issue title
#   $2 - issue body
#   $3 - repo slug
# Echo: parent issue number on stdout, empty if no parent detected
_detect_parent_from_gh_state() {
	local title="$1" body="$2" repo="$3"
	local parent_num=""

	# Method 1: dot-notation in title. Handles any depth of nesting:
	#   t1873.2:       → parent t1873
	#   t1873.2.1:     → parent t1873.2
	#   t2114.1.3.7:   → parent t2114.1.3
	# The previous single-level regex `^(t[0-9]+)\.[0-9]+:` silently dropped
	# every multi-level child because the ":" anchor never matched past the
	# first dotted segment.
	#
	# The regex captures the full dotted prefix up to — but excluding — the
	# final ".N:" segment; _resolve_task_id_via_gh_search is tolerant of
	# dotted IDs (it accepts intermediate levels as search targets).
	if [[ "$title" =~ ^(t[0-9]+(\.[0-9]+)*)\.[0-9]+:[[:space:]] ]]; then
		local dot_parent_tid="${BASH_REMATCH[1]}"
		parent_num=$(_resolve_task_id_via_gh_search "$dot_parent_tid" "$repo")
		if [[ -n "$parent_num" ]]; then
			echo "$parent_num"
			return 0
		fi
	fi

	# Method 2: "Parent:" line in body. Accepts plain ("Parent: tNNN"),
	# bold-markdown ("**Parent:** `tNNN`"), and either a task ID, a raw
	# GitHub number ("#NNN"), or the aidevops GH#NNN notation.
	local parent_ref
	# shellcheck disable=SC2016  # sed regex contains literal backticks and asterisks, no expansion wanted
	parent_ref=$(printf '%s\n' "$body" |
		sed -nE 's/^[[:space:]]*\**Parent:\**[[:space:]]*`?(t[0-9]+|GH#[0-9]+|#[0-9]+)`?.*/\1/p' |
		head -1 || true)
	if [[ -n "$parent_ref" ]]; then
		if [[ "$parent_ref" =~ ^#([0-9]+)$ ]]; then
			echo "${BASH_REMATCH[1]}"
			return 0
		elif [[ "$parent_ref" =~ ^GH#([0-9]+)$ ]]; then
			echo "${BASH_REMATCH[1]}"
			return 0
		elif [[ "$parent_ref" =~ ^(t[0-9]+)$ ]]; then
			parent_num=$(_resolve_task_id_via_gh_search "${BASH_REMATCH[1]}" "$repo")
			if [[ -n "$parent_num" ]]; then
				echo "$parent_num"
				return 0
			fi
		fi
	fi

	# Method 3: "Blocked by:" line listing task IDs; parent-task label on the
	# blocker is required. Supports comma-separated multi-blocker lists; the
	# first parent-tagged blocker wins.
	local blocker_list
	# shellcheck disable=SC2016  # sed regex contains literal backticks and asterisks, no expansion wanted
	blocker_list=$(printf '%s\n' "$body" |
		sed -nE 's/^[[:space:]]*\**Blocked by:\**[[:space:]]*`?([t0-9.,[:space:]]+)`?.*/\1/p' |
		head -1 || true)
	if [[ -n "$blocker_list" ]]; then
		# Normalise separators so whitespace-tolerant input (comma or space)
		# parses the same way.
		local normalised="${blocker_list//,/ }"
		local blocker_id
		for blocker_id in $normalised; do
			blocker_id="${blocker_id// /}"
			[[ -z "$blocker_id" ]] && continue
			[[ "$blocker_id" =~ ^t[0-9]+$ ]] || continue
			local candidate
			candidate=$(_resolve_task_id_via_gh_search "$blocker_id" "$repo")
			[[ -z "$candidate" ]] && continue
			if _issue_has_parent_task_label "$candidate" "$repo"; then
				echo "$candidate"
				return 0
			fi
		done
	fi

	return 0
}

# Link a single child issue as a sub-issue of a detected parent, operating
# purely on GitHub state (title + body). Idempotent — `_gh_add_sub_issue`
# suppresses duplicate-relationship errors.
#
# Arguments:
#   $1 - child issue number
#   $2 - repo slug
#   $3 - (optional) pre-fetched title — avoids redundant gh API call
#   $4 - (optional) pre-fetched body — must be provided alongside $3
# Returns: 0 on success/skip, 1 on unexpected failure
# Echoes one of: "LINKED <child>:<parent>", "SKIPPED <child>", "DRY <child>:<parent>"
_backfill_one_issue() {
	local num="$1" repo="$2" prefetched_title="${3:-}" prefetched_body="${4:-}"
	[[ -z "$num" || -z "$repo" ]] && {
		echo "SKIPPED $num"
		return 0
	}

	# Accept optional pre-fetched title/body to avoid redundant API calls
	# when called from cmd_backfill_sub_issues outer loop (GH#19942).
	local title body
	if [[ -n "$prefetched_title" ]]; then
		title="$prefetched_title"
		body="$prefetched_body"
	else
		local meta
		meta=$(gh issue view "$num" --repo "$repo" --json title,body 2>/dev/null || echo "{}")
		title=$(printf '%s' "$meta" | jq -r '.title // ""' 2>/dev/null)
		body=$(printf '%s' "$meta" | jq -r '.body // ""' 2>/dev/null)
	fi
	if [[ -z "$title" ]]; then
		echo "SKIPPED $num"
		return 0
	fi

	local parent_num
	parent_num=$(_detect_parent_from_gh_state "$title" "$body" "$repo")
	if [[ -z "$parent_num" || "$parent_num" == "$num" ]]; then
		echo "SKIPPED $num"
		return 0
	fi

	if [[ "$DRY_RUN" == "true" ]]; then
		print_info "[DRY-RUN] Would link #$num as sub-issue of #$parent_num"
		echo "DRY $num:$parent_num"
		return 0
	fi

	local child_node parent_node _rate_limited=0
	child_node=$(_cached_node_id "$num" "$repo")
	_node_id_was_rate_limited && _rate_limited=1
	parent_node=$(_cached_node_id "$parent_num" "$repo")
	_node_id_was_rate_limited && _rate_limited=1
	if [[ -z "$child_node" || -z "$parent_node" ]]; then
		log_verbose "#$num: could not resolve node IDs for $num / $parent_num"
		if [[ "$_rate_limited" == "1" ]]; then
			echo "RATE_LIMITED $num"
		else
			echo "SKIPPED $num"
		fi
		return 0
	fi

	if _gh_add_sub_issue "$parent_node" "$child_node"; then
		log_verbose "#$num linked as sub-issue of #$parent_num ✓"
		echo "LINKED $num:$parent_num"
		return 0
	fi
	echo "SKIPPED $num"
	return 0
}

# =============================================================================
# Parent-Side Detection — Umbrella-Style Parent-Task Backfill (GH#19942)
# =============================================================================
# Extends backfill-sub-issues with parent-side detection: when an issue carries
# the `parent-task` label, parse its body for a children section and link every
# referenced child as a sub-issue. Complements the existing child-side path
# that detects parents from child title/body.

# Extract the children section from an issue body. Matches headings:
#   ## Children, ## Child Issues, ## Sub-issues, ## Phases
# (case-insensitive). Returns content from the heading to the next ## heading
# or end of body.
#
# Arguments:
#   $1 - issue body text
# Echo: section content (may be empty if no matching heading found)
_extract_children_section() {
	local body="$1"
	[[ -z "$body" ]] && return 0

	printf '%s\n' "$body" | awk '
		BEGIN { in_section = 0 }
		{
			lower = tolower($0)
			if (lower ~ /^##[[:space:]]+(children|child issues|sub-issues|phases)/) {
				in_section = 1
				next
			}
			if (/^##[[:space:]]/) {
				if (in_section) exit
			}
			if (in_section) print
		}
	'
	return 0
}

# Extract child issue references from a children section. Only matches #NNN
# and GH#NNN references on lines starting with list markers (-, +, *) or
# table cell delimiters (|) to avoid false positives from prose mentions.
#
# Arguments:
#   $1 - children section text (output of _extract_children_section)
# Echo: one issue number per line (deduplicated, sorted numerically)
_extract_child_references() {
	local section="$1"
	[[ -z "$section" ]] && return 0

	printf '%s\n' "$section" |
		grep -E '^[[:space:]]*[-+*|]' |
		grep -oE '(GH)?#[0-9]+' |
		sed -E 's/^(GH)?#//' |
		sort -un
	return 0
}

# Link children listed in a parent-task issue's body section. Parses the body
# for a ## Children (or alias) heading and links every #NNN reference found
# in list items or table cells within that section.
#
# Arguments:
#   $1 - parent issue number
#   $2 - repo slug
#   $3 - issue body (pre-fetched to avoid redundant API calls)
# Echo: "PARENT_LINKED <num>:<count>" or "PARENT_DRY <num>:<count>" or
#       "PARENT_SKIPPED <num>:0"
# Returns: 0 always (errors are logged, not propagated)
_backfill_parent_children() {
	local num="$1" repo="$2" body="$3"
	local _skip_tag="PARENT_SKIPPED"

	[[ -z "$num" || -z "$repo" ]] && {
		echo "${_skip_tag} ${num:-0}:0"
		return 0
	}

	local children_section
	children_section=$(_extract_children_section "$body")
	if [[ -z "$children_section" ]]; then
		log_verbose "#$num: no children section found in body"
		echo "${_skip_tag} $num:0"
		return 0
	fi

	local child_nums_raw
	child_nums_raw=$(_extract_child_references "$children_section")
	if [[ -z "$child_nums_raw" ]]; then
		log_verbose "#$num: children section present but no issue references found"
		echo "${_skip_tag} $num:0"
		return 0
	fi

	# Read into array (bash 3.2 compatible — no mapfile)
	local child_nums=()
	local _cn
	while IFS= read -r _cn; do
		[[ -n "$_cn" ]] && child_nums+=("$_cn")
	done <<< "$child_nums_raw"

	if [[ ${#child_nums[@]} -eq 0 ]]; then
		echo "${_skip_tag} $num:0"
		return 0
	fi

	local linked=0
	local parent_node=""
	local _link_desc="sub-issue of #$num (parent-side)"

	for _cn in "${child_nums[@]}"; do
		# Skip self-references
		[[ "$_cn" == "$num" ]] && continue

		if [[ "$DRY_RUN" == "true" ]]; then
			print_info "[DRY-RUN] Would link #$_cn as ${_link_desc}"
			linked=$((linked + 1))
			continue
		fi

		# Lazy-resolve parent node ID (once, on first real link)
		if [[ -z "$parent_node" ]]; then
			parent_node=$(_cached_node_id "$num" "$repo")
			if [[ -z "$parent_node" ]]; then
				if _node_id_was_rate_limited; then
					log_verbose "#$num: parent node ID resolution hit rate limit"
					echo "PARENT_RATE_LIMITED $num:0"
				else
					log_verbose "#$num: could not resolve parent node ID"
					echo "${_skip_tag} $num:0"
				fi
				return 0
			fi
		fi

		local child_node
		child_node=$(_cached_node_id "$_cn" "$repo")
		if [[ -z "$child_node" ]]; then
			log_verbose "#$_cn: could not resolve child node ID for parent #$num"
			continue
		fi

		if _gh_add_sub_issue "$parent_node" "$child_node"; then
			log_verbose "#$_cn linked as ${_link_desc}"
			linked=$((linked + 1))
		fi
	done

	if [[ "$DRY_RUN" == "true" ]]; then
		echo "PARENT_DRY $num:$linked"
	else
		echo "PARENT_LINKED $num:$linked"
	fi
	return 0
}

# Backfill sub-issue parent-child links for issues in the current repo.
# Detects parents from title/body only — no TODO.md or brief file required.
#
# Usage:
#   cmd_backfill_sub_issues [--issue N]
#
# Without --issue, enumerates open issues in the repo (up to 500) and attempts
# to link each one to its parent. With --issue, operates on a single issue —
# this is the entry point used by the t2112 reconciler for one-issue backfill.
cmd_backfill_sub_issues() {
	local target_issue=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--issue)
			if [[ -z "${2:-}" ]]; then
				print_error "backfill-sub-issues: --issue requires an issue number"
				return 1
			fi
			target_issue="$2"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done

	_init_cmd || return 1
	local repo="$_CMD_REPO"

	local issue_numbers=()
	if [[ -n "$target_issue" ]]; then
		issue_numbers=("$target_issue")
	else
		# Fail fast on gh errors. Previously an auth/network failure turned
		# into `[]` and the run reported "No issues to backfill" — success
		# with no work done, which silently skipped every real candidate
		# and made the pulse t2112 reconcile path believe it had already
		# backfilled an unblessed issue. Any non-zero exit now aborts the
		# command with a clear error and propagates the gh stderr.
		local list_json list_err list_rc
		list_err=$(mktemp) || {
			print_error "backfill-sub-issues: mktemp failed"
			return 1
		}
		list_json=$(gh issue list --repo "$repo" --state open --limit 500 \
			--json number 2>"$list_err")
		list_rc=$?
		if [[ "$list_rc" -ne 0 ]]; then
			print_error "backfill-sub-issues: gh issue list failed for $repo (rc=${list_rc})"
			sed 's/^/  /' "$list_err" >&2 || true
			rm -f "$list_err"
			return 1
		fi
		rm -f "$list_err"
		while IFS= read -r _num; do
			[[ -n "$_num" ]] && issue_numbers+=("$_num")
		done < <(printf '%s' "$list_json" | jq -r '.[].number' 2>/dev/null || true)
	fi

	local total="${#issue_numbers[@]}"
	if [[ $total -eq 0 ]]; then
		print_info "No issues to backfill in $repo"
		return 0
	fi

	print_info "Backfilling sub-issue links for $total issue(s) in $repo"

	local linked=0 skipped=0 rate_limited=0 processed=0
	local _num result meta _title _body _has_parent _pcount
	for _num in "${issue_numbers[@]}"; do
		processed=$((processed + 1))
		if [[ $((processed % 25)) -eq 0 || $processed -eq $total ]]; then
			printf "\r  Progress: %d/%d issues..." "$processed" "$total" >&2
		fi

		# Pre-fetch issue data (title, body, labels) for routing (GH#19942).
		# A single API call per issue avoids double-fetch in both paths.
		meta=$(gh issue view "$_num" --repo "$repo" --json title,body,labels 2>/dev/null || echo "{}")
		_title=$(printf '%s' "$meta" | jq -r '.title // ""' 2>/dev/null)
		_body=$(printf '%s' "$meta" | jq -r '.body // ""' 2>/dev/null)
		_has_parent=$(printf '%s' "$meta" | jq -r '[.labels[].name] | any(. == "parent-task")' 2>/dev/null || echo "false")

		if [[ "$_has_parent" == "true" ]]; then
			# Parent-side: parse body for children section and link downward
			result=$(_backfill_parent_children "$_num" "$repo" "$_body" | tail -1)
		else
			# Child-side: detect parent from title/body and link upward
			result=$(_backfill_one_issue "$_num" "$repo" "$_title" "$_body" | tail -1)
		fi

		case "$result" in
		LINKED*) linked=$((linked + 1)) ;;
		DRY*) linked=$((linked + 1)) ;;
		PARENT_LINKED*|PARENT_DRY*)
			_pcount="${result##*:}"
			linked=$((linked + _pcount))
			;;
		# RATE_LIMITED / PARENT_RATE_LIMITED: node ID could not be resolved due to
		# GraphQL exhaustion and REST also failing. Counted separately so callers
		# (pulse t2112 reconciler) can re-enqueue rather than treating as permanent.
		RATE_LIMITED*|PARENT_RATE_LIMITED*) rate_limited=$((rate_limited + 1)) ;;
		*) skipped=$((skipped + 1)) ;;
		esac
	done
	[[ $total -gt 25 ]] && printf "\n" >&2

	printf "\n=== Backfill Sub-Issues ===\nLinked: %d | Skipped: %d | Rate-limited: %d | Issues processed: %d\n" \
		"$linked" "$skipped" "$rate_limited" "$total"
	return 0
}
