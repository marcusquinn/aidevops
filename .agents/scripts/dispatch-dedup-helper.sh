#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# dispatch-dedup-helper.sh - Normalize and deduplicate worker dispatch titles (t2310)
#
# Prevents duplicate worker dispatch by extracting canonical dedup keys from
# worker process titles, issue/PR numbers, and task IDs. The pulse agent calls
# this before dispatching to check if a worker is already running for the same
# issue, PR, or task.
#
# The root cause (issue #2310): title matching is not normalized. The same issue
# can be dispatched with different title formats:
#   - "issue-2300-simplify-infra-scripts"
#   - "Issue #2300: t1337 Simplify Tier 3 infrastructure scripts"
#   - "t1337: Simplify Tier 3 over-engineered infrastructure scripts"
# All three refer to issue #2300 / task t1337, but raw string comparison misses this.
#
# Solution: extract canonical dedup keys (issue-NNN, pr-NNN, task-tNNN) from any
# title format, then compare keys instead of raw strings.
#
# Usage:
#   dispatch-dedup-helper.sh extract-keys <title>
#     Extract dedup keys from a title string. Returns one key per line.
#
#   dispatch-dedup-helper.sh is-duplicate <title>
#     Check if any running worker already covers the same issue/PR/task.
#     Exit 0 = duplicate found (do NOT dispatch), exit 1 = no duplicate (safe to dispatch).
#
#   dispatch-dedup-helper.sh has-open-pr <issue> <slug> [issue-title]
#     Check whether an issue already has merged PR evidence (closing keyword or
#     task-id fallback) and should be skipped by pulse dispatch.
#     Exit 0 = PR evidence exists (do NOT dispatch), exit 1 = no evidence.
#
#   dispatch-dedup-helper.sh is-assigned <issue> <slug> [self-login]
#     Check if issue is assigned to another runner (not self, owner, or maintainer).
#     GH#10521: Ignores repo owner (from slug) and maintainer (from repos.json).
#     Exit 0 = assigned to another runner (do NOT dispatch), exit 1 = safe to dispatch.
#
#   dispatch-dedup-helper.sh list-running-keys
#     List dedup keys for all currently running workers.
#
#   dispatch-dedup-helper.sh claim <issue> <slug> [runner-login]
#     Cross-machine optimistic lock via GitHub comments (t1686).
#     Exit 0 = claim won (safe to dispatch), exit 1 = lost, exit 2 = error (fail-open).
#
#   dispatch-dedup-helper.sh normalize <title>
#     Return the normalized (lowercased, stripped) form of a title for comparison.

set -euo pipefail

# Resolve path to dispatch-claim-helper.sh (co-located)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
CLAIM_HELPER="${SCRIPT_DIR}/dispatch-claim-helper.sh"

#######################################
# Extract canonical dedup keys from a title string.
# Looks for patterns: issue #NNN, PR #NNN, tNNN (task IDs), issue-NNN, pr-NNN.
# Args: $1 = title string
# Returns: one key per line on stdout (e.g., "issue-2300", "task-t1337")
#######################################
extract_keys() {
	local title="$1"
	local keys=()

	# Normalize to lowercase for pattern matching
	local lower_title
	lower_title=$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]')

	# Pattern 1: Explicit "issue #NNN" or "issue-NNN" (not bare #NNN)
	local issue_nums
	issue_nums=$(printf '%s' "$lower_title" | grep -oE 'issue\s*#?[0-9]+|issue-[0-9]+' | grep -oE '[0-9]+' || true)
	if [[ -n "$issue_nums" ]]; then
		while IFS= read -r num; do
			[[ -n "$num" ]] && keys+=("issue-${num}")
		done <<<"$issue_nums"
	fi

	# Pattern 2: "pr #NNN" or "pr-NNN" or "pull #NNN"
	local pr_nums
	pr_nums=$(printf '%s' "$lower_title" | grep -oE '(pr\s*#?|pr-|pull\s*#?)[0-9]+' | grep -oE '[0-9]+' || true)
	if [[ -n "$pr_nums" ]]; then
		while IFS= read -r num; do
			[[ -n "$num" ]] && keys+=("pr-${num}")
		done <<<"$pr_nums"
	fi

	# Pattern 2b: Bare "#NNN" (GitHub-style reference, could be issue or PR)
	# Produces a generic ref-NNN key that matches against both issue-NNN and pr-NNN
	local bare_refs
	bare_refs=$(printf '%s' "$lower_title" | grep -oE '(^|[^a-z])#([0-9]+)' | grep -oE '[0-9]+' || true)
	if [[ -n "$bare_refs" ]]; then
		while IFS= read -r num; do
			[[ -n "$num" ]] && keys+=("ref-${num}")
		done <<<"$bare_refs"
	fi

	# Pattern 3: task IDs "tNNN" (e.g., t1337, t128.5)
	local task_ids
	task_ids=$(printf '%s' "$lower_title" | grep -oE '\bt[0-9]+(\.[0-9]+)?\b' || true)
	if [[ -n "$task_ids" ]]; then
		while IFS= read -r tid; do
			[[ -n "$tid" ]] && keys+=("task-${tid}")
		done <<<"$task_ids"
	fi

	# Pattern 4: Branch-style "issue-NNN-" or "pr-NNN-" (from worktree names)
	# Use a portable fallback chain: rg (ripgrep) → ggrep -P (GNU grep on macOS) → grep -E
	local branch_issue_nums
	if command -v rg &>/dev/null; then
		branch_issue_nums=$(printf '%s' "$lower_title" | rg -o 'issue-([0-9]+)' | grep -oE '[0-9]+' || true)
	elif command -v ggrep &>/dev/null && ggrep -P '' /dev/null 2>/dev/null; then
		branch_issue_nums=$(printf '%s' "$lower_title" | ggrep -oP 'issue-\K[0-9]+' || true)
	else
		branch_issue_nums=$(printf '%s' "$lower_title" | grep -oE 'issue-([0-9]+)' | grep -oE '[0-9]+' || true)
	fi
	if [[ -n "$branch_issue_nums" ]]; then
		while IFS= read -r num; do
			[[ -n "$num" ]] && keys+=("issue-${num}")
		done <<<"$branch_issue_nums"
	fi

	# Deduplicate keys
	if [[ ${#keys[@]} -gt 0 ]]; then
		printf '%s\n' "${keys[@]}" | sort -u
	fi

	return 0
}

#######################################
# Normalize a title for fuzzy comparison.
# Lowercases, strips punctuation, collapses whitespace.
# Args: $1 = title string
# Returns: normalized string on stdout
#######################################
normalize_title() {
	local title="$1"

	printf '%s' "$title" |
		tr '[:upper:]' '[:lower:]' |
		sed 's/[^a-z0-9 ]/ /g' |
		tr -s ' ' |
		sed 's/^ //; s/ $//'

	return 0
}

#######################################
# List dedup keys for all currently running workers.
# Scans process list for /full-loop workers and extracts keys from their titles.
# Returns: one "pid|key" pair per line on stdout
#######################################
list_running_keys() {
	# Get PIDs of running worker processes using portable pgrep -f (no -a flag).
	# pgrep -f matches against the full command line on both Linux and macOS.
	# We then resolve the full command line per PID via ps -p <pid> -o args=
	# which is POSIX-compatible and works on Linux, macOS, and BSD.
	local worker_pids=""
	worker_pids=$(pgrep -f '/full-loop|opencode run|claude.*run' || true)

	if [[ -z "$worker_pids" ]]; then
		return 0
	fi

	while IFS= read -r pid; do
		[[ -z "$pid" ]] && continue
		local cmdline=""
		# ps -p <pid> -o args= prints only the command line (no header, no PID prefix)
		cmdline=$(ps -p "$pid" -o args= 2>/dev/null || true)
		[[ -z "$cmdline" ]] && continue

		local extracted_keys=""
		extracted_keys=$(extract_keys "$cmdline")
		if [[ -n "$extracted_keys" ]]; then
			while IFS= read -r key; do
				[[ -n "$key" ]] && printf '%s|%s\n' "$pid" "$key"
			done <<<"$extracted_keys"
		fi
	done <<<"$worker_pids"

	return 0
}

#######################################
# Check one candidate key against running process keys.
# Handles cross-type matching: ref-NNN matches issue-NNN and pr-NNN.
# Args: $1 = candidate key (e.g., "issue-2300", "ref-42", "task-t1337")
#       $2 = newline-separated "pid|key" pairs from list_running_keys
# Returns: exit 0 if match found (prints DUPLICATE line),
#          exit 1 if no match
#######################################
_match_candidate_key() {
	local candidate_key="$1"
	local running_keys="$2"

	local -a match_patterns=("$candidate_key")
	local key_type key_num
	key_type=$(printf '%s' "$candidate_key" | cut -d'-' -f1)
	key_num=$(printf '%s' "$candidate_key" | cut -d'-' -f2-)

	# ref-NNN should match issue-NNN and pr-NNN (and vice versa)
	case "$key_type" in
	ref)
		match_patterns+=("issue-${key_num}" "pr-${key_num}")
		;;
	issue | pr)
		match_patterns+=("ref-${key_num}")
		;;
	esac

	local pattern
	for pattern in "${match_patterns[@]}"; do
		local match
		match=$(printf '%s\n' "$running_keys" | grep "|${pattern}$" | head -1 || true)
		if [[ -n "$match" ]]; then
			local match_pid
			match_pid=$(printf '%s' "$match" | cut -d'|' -f1)
			printf 'DUPLICATE: key=%s matches running %s (PID %s)\n' "$candidate_key" "$pattern" "$match_pid"
			return 0
		fi
	done

	return 1
}

#######################################
# Query supervisor DB for one candidate key and verify PID liveness.
# GH#5662: stale DB entries (dead PIDs, missing PID files) are reset to
# 'failed' and treated as safe to dispatch.
# Args: $1 = candidate key (e.g., "issue-2300", "task-t1337", "pr-42")
#       $2 = path to supervisor.db
# Returns: exit 0 if live duplicate found (prints DUPLICATE line),
#          exit 1 if no match or stale entry (prints STALE line if stale)
#######################################
_check_db_entry() {
	local candidate_key="$1"
	local supervisor_db="$2"

	local key_type key_num
	key_type=$(printf '%s' "$candidate_key" | cut -d'-' -f1)
	key_num=$(printf '%s' "$candidate_key" | cut -d'-' -f2-)

	local db_match=""
	case "$key_type" in
	issue)
		db_match=$(sqlite3 "$supervisor_db" "
			SELECT id FROM tasks
			WHERE status IN ('running', 'dispatched', 'evaluating')
			AND (description LIKE '%#${key_num}%'
			     OR description LIKE '%issue ${key_num}%'
			     OR description LIKE '%issue-${key_num}%')
			LIMIT 1;
		" 2>/dev/null || true)
		;;
	task)
		db_match=$(sqlite3 "$supervisor_db" "
			SELECT id FROM tasks
			WHERE status IN ('running', 'dispatched', 'evaluating')
			AND id = '${key_num}'
			LIMIT 1;
		" 2>/dev/null || true)
		;;
	pr)
		db_match=$(sqlite3 "$supervisor_db" "
			SELECT id FROM tasks
			WHERE status IN ('running', 'dispatched', 'evaluating')
			AND (pr_url LIKE '%/${key_num}'
			     OR description LIKE '%PR #${key_num}%'
			     OR description LIKE '%pr-${key_num}%')
			LIMIT 1;
		" 2>/dev/null || true)
		;;
	esac

	[[ -z "$db_match" ]] && return 1

	# GH#5662: Verify the stored PID is still alive before reporting duplicate.
	local supervisor_dir="${SUPERVISOR_DIR:-${HOME}/.aidevops/.agent-workspace/supervisor}"
	local pid_file="${supervisor_dir}/pids/${db_match}.pid"
	local stored_pid=""
	[[ -f "$pid_file" ]] && stored_pid=$(cat "$pid_file" 2>/dev/null || true)

	if [[ -n "$stored_pid" ]] && [[ "$stored_pid" =~ ^[0-9]+$ ]]; then
		if ! kill -0 "$stored_pid" 2>/dev/null; then
			# Process is dead — stale DB entry; reset and allow dispatch
			sqlite3 "$supervisor_db" "
				UPDATE tasks SET status = 'failed',
				  error = 'stale: PID ${stored_pid} not running (GH#5662)',
				  updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
				WHERE id = '$(printf '%s' "$db_match" | sed "s/'/''/g")';
			" 2>/dev/null || true
			printf 'STALE: key=%s task %s PID %s is dead — entry reset, safe to dispatch\n' \
				"$candidate_key" "$db_match" "$stored_pid"
			return 1
		fi
		# PID is alive — genuine duplicate
		printf 'DUPLICATE: key=%s already active in supervisor DB (task %s PID %s)\n' \
			"$candidate_key" "$db_match" "$stored_pid"
		return 0
	fi

	# No PID file or non-numeric content — treat as stale (GH#5662)
	printf 'STALE: key=%s task %s has no valid PID file — treating as stale, safe to dispatch\n' \
		"$candidate_key" "$db_match"
	sqlite3 "$supervisor_db" "
		UPDATE tasks SET status = 'failed',
		  error = 'stale: no PID file found (GH#5662)',
		  updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
		WHERE id = '$(printf '%s' "$db_match" | sed "s/'/''/g")';
	" 2>/dev/null || true
	return 1
}

#######################################
# Check if a title's dedup keys overlap with any running worker.
# Args: $1 = title of the item to be dispatched
# Returns: exit 0 if duplicate found (do NOT dispatch),
#          exit 1 if no duplicate (safe to dispatch)
# Outputs: matching key and PID on stdout if duplicate found
#
# GH#5662: When a supervisor DB match is found, the stored PID is verified
# with kill -0 before returning exit 0. Dead PIDs cause the stale DB entry
# to be reset to 'failed' and exit 1 is returned (safe to dispatch).
#######################################
is_duplicate() {
	local title="$1"

	# Extract keys from the candidate title
	local candidate_keys
	candidate_keys=$(extract_keys "$title")

	if [[ -z "$candidate_keys" ]]; then
		# No extractable keys — cannot deduplicate, allow dispatch
		return 1
	fi

	# Check against running worker processes
	local running_keys
	running_keys=$(list_running_keys)

	if [[ -n "$running_keys" ]]; then
		while IFS= read -r candidate_key; do
			[[ -z "$candidate_key" ]] && continue
			if _match_candidate_key "$candidate_key" "$running_keys"; then
				return 0
			fi
		done <<<"$candidate_keys"
	fi

	# Also check the supervisor DB if available
	local supervisor_db="${SUPERVISOR_DIR:-${HOME}/.aidevops/.agent-workspace/supervisor}/supervisor.db"
	if [[ -f "$supervisor_db" ]] && command -v sqlite3 &>/dev/null; then
		while IFS= read -r candidate_key; do
			[[ -z "$candidate_key" ]] && continue
			if _check_db_entry "$candidate_key" "$supervisor_db"; then
				return 0
			fi
		done <<<"$candidate_keys"
	fi

	# No duplicates found
	return 1
}

#######################################
# Get the repo owner from the slug.
# Args: $1 = repo slug (owner/repo)
# Returns: owner login on stdout (empty if invalid)
#######################################
_get_repo_owner() {
	local repo_slug="$1"

	if [[ -z "$repo_slug" || "$repo_slug" != */* ]]; then
		return 0
	fi

	printf '%s' "${repo_slug%%/*}"
	return 0
}

#######################################
# Look up the repo maintainer from repos.json.
# The maintainer is the repo owner/admin — not a runner account.
# Args: $1 = repo slug (owner/repo)
# Returns: maintainer login on stdout (empty if not found)
#######################################
_get_repo_maintainer() {
	local repo_slug="$1"
	local repos_json="${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"

	if [[ ! -f "$repos_json" ]]; then
		return 0
	fi

	local maintainer=""
	maintainer=$(jq -r --arg slug "$repo_slug" \
		'.initialized_repos[] | select(.slug == $slug) | .maintainer // empty' \
		"$repos_json" 2>/dev/null) || maintainer=""

	printf '%s' "$maintainer"
	return 0
}

#######################################
# Stale assignment recovery (GH#15060)
#
# When an issue is assigned to a blocking user (another runner), check
# whether that assignment is stale: no active worker process, dispatch
# claim comment is >1h old, and no progress (comments) in the last hour.
#
# If stale, unassign the blocking users, remove status:queued and
# status:in-progress labels (they are lies — no worker is running),
# post a recovery comment for audit trail, and return 0 (stale, safe
# to re-dispatch). The caller then proceeds with dispatch.
#
# This breaks the orphaned-assignment deadlock where a runner goes
# offline and leaves hundreds of issues assigned to it. Without this,
# the dedup guard permanently blocks all dispatch (0 workers, 100%
# failure rate observed in production — 370 issues, 159 PRs stuck).
#
# The 1-hour threshold is conservative: any legitimate worker would
# have produced at least one comment or commit within an hour. Workers
# that crash or exit without cleanup leave the assignment orphaned.
#
# Args:
#   $1 = issue number
#   $2 = repo slug (owner/repo)
#   $3 = comma-separated blocking assignee logins
# Returns:
#   exit 0 = stale assignment recovered (safe to dispatch)
#   exit 1 = assignment is NOT stale (genuine active claim, block dispatch)
#######################################
STALE_ASSIGNMENT_THRESHOLD_SECONDS="${STALE_ASSIGNMENT_THRESHOLD_SECONDS:-3600}" # 1 hour

_is_stale_assignment() {
	local issue_number="$1"
	local repo_slug="$2"
	local blocking_assignees="$3"

	# Fetch issue comments to find the most recent dispatch claim and
	# overall activity timestamp. Use --paginate to catch all comments
	# on issues with long histories, but cap with --jq to only extract
	# what we need (timestamp + body snippet for matching).
	local comments_json
	comments_json=$(gh api "repos/${repo_slug}/issues/${issue_number}/comments" \
		--jq '[.[] | {created_at: .created_at, author: .user.login, body_start: (.body[:200])}] | sort_by(.created_at) | reverse' \
		2>/dev/null) || comments_json="[]"

	# Find the most recent dispatch/claim comment
	# Matches: "Dispatching worker", "DISPATCH_CLAIM", "Worker (PID"
	local last_dispatch_ts=""
	last_dispatch_ts=$(printf '%s' "$comments_json" | jq -r '
		[.[] | select(
			(.body_start | test("Dispatching worker"; "i")) or
			(.body_start | test("DISPATCH_CLAIM"; "i")) or
			(.body_start | test("Worker \\(PID"; "i"))
		)] | first | .created_at // empty
	' 2>/dev/null) || last_dispatch_ts=""

	# Find the most recent comment of any kind (progress signal)
	local last_activity_ts=""
	last_activity_ts=$(printf '%s' "$comments_json" | jq -r '
		first | .created_at // empty
	' 2>/dev/null) || last_activity_ts=""

	# If no dispatch comment exists at all, the assignment is from a
	# non-worker source (e.g., auto-assignment at issue creation). Treat
	# as stale since there's no worker claim to protect.
	local now_epoch dispatch_epoch activity_epoch
	now_epoch=$(date +%s)

	if [[ -z "$last_dispatch_ts" ]]; then
		# No dispatch comment — check if the last activity is also old
		if [[ -n "$last_activity_ts" ]]; then
			activity_epoch=$(_ts_to_epoch "$last_activity_ts")
			local activity_age=$((now_epoch - activity_epoch))
			if [[ "$activity_age" -lt "$STALE_ASSIGNMENT_THRESHOLD_SECONDS" ]]; then
				# Recent activity but no dispatch comment — could be manual work
				return 1
			fi
		fi
		# No dispatch comment AND no recent activity — stale
		_recover_stale_assignment "$issue_number" "$repo_slug" "$blocking_assignees" "no dispatch claim comment found, no recent activity"
		return 0
	fi

	# Dispatch comment exists — check its age
	dispatch_epoch=$(_ts_to_epoch "$last_dispatch_ts")
	local dispatch_age=$((now_epoch - dispatch_epoch))

	if [[ "$dispatch_age" -lt "$STALE_ASSIGNMENT_THRESHOLD_SECONDS" ]]; then
		# Dispatch claim is recent (< threshold) — honour it
		return 1
	fi

	# Dispatch claim is old. Check if there's been any progress since.
	if [[ -n "$last_activity_ts" ]]; then
		activity_epoch=$(_ts_to_epoch "$last_activity_ts")
		local activity_age=$((now_epoch - activity_epoch))
		if [[ "$activity_age" -lt "$STALE_ASSIGNMENT_THRESHOLD_SECONDS" ]]; then
			# Old dispatch but recent activity — worker may still be alive
			return 1
		fi
	fi

	# Both dispatch claim and last activity are older than threshold — stale
	_recover_stale_assignment "$issue_number" "$repo_slug" "$blocking_assignees" \
		"dispatch claim ${dispatch_age}s old, last activity ${activity_age:-unknown}s old"
	return 0
}

#######################################
# Convert ISO 8601 timestamp to epoch seconds
# Handles both "2026-03-31T23:59:07Z" and "2026-03-31T23:59:07+00:00" formats.
# Bash 3.2 compatible (no date -d on macOS).
# Args: $1 = ISO timestamp
# Returns: epoch seconds on stdout
#######################################
_ts_to_epoch() {
	local ts="$1"
	# macOS date -j -f parses a formatted date string
	if [[ "$(uname)" == "Darwin" ]]; then
		# Strip trailing Z or timezone offset for macOS date parsing
		local clean_ts="${ts%%Z*}"
		clean_ts="${clean_ts%%+*}"
		date -j -f "%Y-%m-%dT%H:%M:%S" "$clean_ts" "+%s" 2>/dev/null || echo "0"
	else
		date -d "$ts" "+%s" 2>/dev/null || echo "0"
	fi
	return 0
}

#######################################
# Execute stale assignment recovery: unassign, relabel, comment
# Args:
#   $1 = issue number
#   $2 = repo slug
#   $3 = comma-separated stale assignee logins
#   $4 = reason string for audit trail
#######################################
_recover_stale_assignment() {
	local issue_number="$1"
	local repo_slug="$2"
	local stale_assignees="$3"
	local reason="$4"

	# Unassign all stale users
	local saved_ifs="${IFS:-}"
	local -a assignee_arr=()
	IFS=',' read -ra assignee_arr <<<"$stale_assignees"
	IFS="$saved_ifs"

	for assignee in "${assignee_arr[@]}"; do
		gh issue edit "$issue_number" --repo "$repo_slug" \
			--remove-assignee "$assignee" 2>/dev/null || true
	done

	# Remove stale status labels — they are lies (no worker is running)
	gh issue edit "$issue_number" --repo "$repo_slug" \
		--remove-label "status:queued" --remove-label "status:in-progress" \
		--add-label "status:available" 2>/dev/null || true

	# Post audit comment
	gh issue comment "$issue_number" --repo "$repo_slug" \
		--body "**Stale assignment recovered** (GH#15060)

Previously assigned to: ${stale_assignees}
Reason: ${reason}
Threshold: ${STALE_ASSIGNMENT_THRESHOLD_SECONDS}s

The assigned runner had no active worker process and produced no progress within the threshold. Unassigned and relabeled \`status:available\` for re-dispatch.

_This recovery prevents the orphaned-assignment deadlock where offline runners permanently block all dispatch._" 2>/dev/null || true

	printf 'STALE_RECOVERED: issue #%s in %s — unassigned %s (%s)\n' \
		"$issue_number" "$repo_slug" "$stale_assignees" "$reason"
	return 0
}

#######################################
# Check if a GitHub issue is already assigned to another runner.
#
# This is the primary cross-machine dedup guard. Process-based checks
# (is_duplicate, has_worker_for_repo_issue) only see local processes —
# they miss workers running on other machines. The GitHub assignee is
# the single source of truth visible to all runners.
#
# Owner/maintainer assignment carries two different meanings:
#   1. passive backlog ownership / maintainer review bookkeeping
#   2. active worker claim (when paired with status:queued/in-progress)
#
# Treating all owner/maintainer assignees as active claims created a queue
# starvation bug: the pulse discovers unassigned issues by default, while
# several tooling pipelines auto-assigned newly created debt issues to the
# maintainer. The result was hundreds of open issues that looked "claimed"
# to the deterministic guard but had no worker, no queued state, and no PR.
#
# Systemic rule:
# - self_login never blocks
# - owner/maintainer assignees are passive unless the issue has an active
#   claim status label (status:queued or status:in-progress)
# - any other assignee blocks dispatch — UNLESS the assignment is stale
#   (no active worker, dispatch claim >1h old, no recent progress).
#   Stale assignments are auto-recovered (GH#15060).
#
# This preserves GH#10521 (maintainer assignment alone must not starve the
# queue) while still protecting GH#11141 (owner-assigned queued work must
# block other runners once a real claim is active).
#
# Args:
#   $1 = issue number
#   $2 = repo slug (owner/repo)
#   $3 = (optional) current runner login — if assigned to self, not a dup
# Returns:
#   exit 0 if assigned to another login (do NOT dispatch)
#   exit 1 if unassigned or assigned only to self (safe to dispatch)
# Outputs: assignee info on stdout if assigned to another login
#######################################
is_assigned() {
	local issue_number="$1"
	local repo_slug="$2"
	local self_login="${3:-}"

	if [[ -z "$issue_number" || -z "$repo_slug" ]]; then
		# Missing args — cannot check, allow dispatch
		return 1
	fi

	# Validate issue number is numeric
	if [[ ! "$issue_number" =~ ^[0-9]+$ ]]; then
		return 1
	fi

	local issue_meta_json
	issue_meta_json=$(gh issue view "$issue_number" --repo "$repo_slug" \
		--json state,assignees,labels 2>/dev/null) || issue_meta_json=""

	if [[ -z "$issue_meta_json" ]]; then
		return 1
	fi

	# Query GitHub for current assignees
	local assignees
	assignees=$(printf '%s' "$issue_meta_json" | jq -r '[.assignees[].login] | join(",")' 2>/dev/null) || assignees=""

	if [[ -z "$assignees" ]]; then
		# No assignees — safe to dispatch
		return 1
	fi

	local repo_owner repo_maintainer has_active_status
	repo_owner=$(_get_repo_owner "$repo_slug")
	repo_maintainer=$(_get_repo_maintainer "$repo_slug")
	has_active_status=$(printf '%s' "$issue_meta_json" | jq -r '([.labels[].name] | (index("status:queued") != null or index("status:in-progress") != null))' 2>/dev/null)
	[[ "$has_active_status" == "true" || "$has_active_status" == "false" ]] || has_active_status="false"

	local -a assignee_array=()
	local saved_ifs="${IFS:-}"
	IFS=',' read -ra assignee_array <<<"$assignees"
	IFS="$saved_ifs"

	local blocking_assignees=""
	local assignee
	for assignee in "${assignee_array[@]}"; do
		if [[ -n "$self_login" && "$assignee" == "$self_login" ]]; then
			continue
		fi

		if [[ "$assignee" == "$repo_owner" || (-n "$repo_maintainer" && "$assignee" == "$repo_maintainer") ]]; then
			if [[ "$has_active_status" != "true" ]]; then
				continue
			fi
		fi

		if [[ -n "$blocking_assignees" ]]; then
			blocking_assignees="${blocking_assignees},${assignee}"
		else
			blocking_assignees="$assignee"
		fi
	done

	if [[ -z "$blocking_assignees" ]]; then
		# Only passive assignees remain (self and/or owner/maintainer without
		# active claim state) — safe to dispatch.
		return 1
	fi

	# Stale assignment recovery (GH#15060): if the blocking assignee has no
	# active worker process AND the most recent dispatch/claim comment is >1h
	# old AND there's been no progress (no new comments) in the last hour,
	# treat the assignment as abandoned. Unassign the stale user, remove
	# queued/in-progress labels, and allow re-dispatch.
	#
	# Root cause: when a runner goes offline or a worker crashes without
	# cleanup, the issue stays assigned to that runner forever. The dedup
	# guard blocks all other runners from dispatching for it, creating a
	# permanent deadlock where 0 workers run despite available slots and
	# open issues. This was observed in production with 370 issues and 0
	# active workers — 100% dispatch failure rate.
	if _is_stale_assignment "$issue_number" "$repo_slug" "$blocking_assignees"; then
		return 1
	fi

	printf 'ASSIGNED: issue #%s in %s is assigned to %s\n' "$issue_number" "$repo_slug" "$blocking_assignees"
	return 0
}

#######################################
# Check whether an issue already has merged PR evidence.
#
# Historical note: command name is `has-open-pr` to match pulse-wrapper
# dispatch dedup call sites from review feedback, but the underlying behavior
# checks merged PR evidence to avoid redispatching already-completed issues.
#
# Args:
#   $1 = issue number
#   $2 = repo slug (owner/repo)
#   $3 = issue title (optional; used for task-id fallback)
# Returns:
#   exit 0 if merged PR evidence exists (do NOT dispatch)
#   exit 1 if no merged PR evidence (safe to dispatch)
# Outputs:
#   single-line reason when evidence is found
#######################################
has_open_pr() {
	local issue_number="$1"
	local repo_slug="$2"
	local issue_title="${3:-}"

	if [[ ! "$issue_number" =~ ^[0-9]+$ ]] || [[ -z "$repo_slug" ]]; then
		return 1
	fi

	local query pr_json pr_count pr_number
	for keyword in close closes closed fix fixes fixed resolve resolves resolved; do
		query="${keyword} #${issue_number} in:body"
		pr_json=$(gh pr list --repo "$repo_slug" --state merged --search "$query" --limit 1 --json number 2>/dev/null) || pr_json="[]"
		pr_count=$(printf '%s' "$pr_json" | jq 'length' 2>/dev/null) || pr_count=0
		[[ "$pr_count" =~ ^[0-9]+$ ]] || pr_count=0
		if [[ "$pr_count" -gt 0 ]]; then
			pr_number=$(printf '%s' "$pr_json" | jq -r '.[0].number // empty' 2>/dev/null)
			if [[ -n "$pr_number" ]]; then
				# Verify the PR body contains an exact close reference for this issue.
				# GitHub search is full-text: a PR with "Closes #621" and "v3.5.670"
				# would falsely match issue #670. Post-filter with exact regex.
				local pr_body
				pr_body=$(gh pr view "$pr_number" --repo "$repo_slug" --json body --jq '.body' 2>/dev/null) || pr_body=""
				# Match: keyword + optional whitespace + #NNN or owner/repo#NNN followed by a non-word char or end
				local close_pattern="(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]+([a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+)?#${issue_number}([^[:alnum:]_]|$)"
				if ! printf '%s' "$pr_body" | grep -iqE "$close_pattern"; then
					continue
				fi
				printf 'merged PR #%s references issue #%s via "%s" keyword\n' "$pr_number" "$issue_number" "$keyword"
			else
				printf 'merged PR references issue #%s via "%s" keyword\n' "$issue_number" "$keyword"
			fi
			return 0
		fi
	done

	local task_id
	task_id=$(printf '%s' "$issue_title" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1 || true)
	if [[ -z "$task_id" ]]; then
		return 1
	fi

	query="${task_id} in:title"
	pr_json=$(gh pr list --repo "$repo_slug" --state merged --search "$query" --limit 1 --json number 2>/dev/null) || pr_json="[]"
	pr_count=$(printf '%s' "$pr_json" | jq 'length' 2>/dev/null) || pr_count=0
	[[ "$pr_count" =~ ^[0-9]+$ ]] || pr_count=0
	if [[ "$pr_count" -gt 0 ]]; then
		pr_number=$(printf '%s' "$pr_json" | jq -r '.[0].number // empty' 2>/dev/null)
		if [[ -n "$pr_number" ]]; then
			printf 'merged PR #%s found by task id %s in title\n' "$pr_number" "$task_id"
		else
			printf 'merged PR found by task id %s in title\n' "$task_id"
		fi
		return 0
	fi
	return 1
}

#######################################
# Check whether an issue has an active claim state.
# Active = OPEN + has assignee + has status:queued or status:in-progress label.
# Args: $1 = issue number, $2 = repo slug
# Returns: exit 0 if actively claimed, exit 1 otherwise
# Outputs: issue_meta_json on stdout (for reuse by caller)
#######################################
_get_active_claim_meta() {
	local issue_number="$1"
	local repo_slug="$2"

	local issue_meta_json
	issue_meta_json=$(gh issue view "$issue_number" --repo "$repo_slug" --json state,assignees,labels 2>/dev/null) || issue_meta_json=""
	if [[ -z "$issue_meta_json" ]]; then
		return 1
	fi

	local is_open has_assignee has_active_status
	is_open=$(printf '%s' "$issue_meta_json" | jq -r '.state == "OPEN"' 2>/dev/null)
	has_assignee=$(printf '%s' "$issue_meta_json" | jq -r '(.assignees | length) > 0' 2>/dev/null)
	has_active_status=$(printf '%s' "$issue_meta_json" | jq -r '([.labels[].name] | (index("status:queued") != null or index("status:in-progress") != null))' 2>/dev/null)

	[[ "$is_open" == "true" || "$is_open" == "false" ]] || is_open="false"
	[[ "$has_assignee" == "true" || "$has_assignee" == "false" ]] || has_assignee="false"
	[[ "$has_active_status" == "true" || "$has_active_status" == "false" ]] || has_active_status="false"

	if [[ "$is_open" != "true" || "$has_assignee" != "true" || "$has_active_status" != "true" ]]; then
		return 1
	fi

	return 0
}

#######################################
# Check whether a single dispatch comment is still active (within TTL and
# backed by a live local worker process).
#
# GH#16626: Process liveness check — if the comment is within TTL but no
# worker process is running for this issue locally, the worker completed or
# crashed without cleanup. Treat as stale and allow re-dispatch.
# Grace period: comments <5 min old skip the liveness check to avoid racing
# with worker startup (process may not be visible yet).
#
# Args:
#   $1 = comment created_at (ISO 8601)
#   $2 = comment author login
#   $3 = issue number (for process search)
#   $4 = now_epoch (seconds since epoch)
#   $5 = max_age (seconds)
# Returns: exit 0 if comment is active (blocks dispatch), exit 1 if stale/expired
# Outputs: reason string on stdout when active
#######################################
_is_dispatch_comment_active() {
	local created_at="$1"
	local author="$2"
	local issue_number="$3"
	local now_epoch="$4"
	local max_age="$5"

	[[ -z "$created_at" ]] && return 1

	local comment_epoch
	comment_epoch=$(date -u -d "$created_at" '+%s' 2>/dev/null ||
		TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$created_at" '+%s' 2>/dev/null ||
		printf '%s' "0")
	local age=$((now_epoch - comment_epoch))

	# GH#17503: Straight TTL check — no pgrep escape hatch, no grace period.
	# The dispatch comment blocks re-dispatch for the full TTL duration.
	# Comments are never deleted (audit trail); they just stop blocking
	# after max_age expires, allowing a fresh dispatch attempt.
	[[ "$age" -ge "$max_age" ]] && return 1

	printf 'dispatch comment by %s posted %ds ago on issue #%s (TTL: %ds remaining)\n' \
		"$author" "$age" "$issue_number" "$((max_age - age))"
	return 0
}

#######################################
# Check whether an issue has a recent "Dispatching worker" comment (GH#11141).
#
# The pulse agent posts a "Dispatching worker" comment on every issue
# it dispatches. This is a persistent, cross-machine signal that a
# worker is in-flight — unlike the dispatch ledger (local-only) or
# the claim lock (8-second window). Checking for this comment catches
# the gap between dispatch and PR creation across machines.
#
# GH#17503: This is now the PRIMARY dedup guard. Dispatch comments are
# never deleted (audit trail). A dispatch comment blocks re-dispatch for
# DISPATCH_COMMENT_MAX_AGE seconds (default 1800 = 30 min). After that,
# the comment stays for audit but no longer blocks — allowing a fresh
# dispatch attempt.
#
# A completion or failure comment posted AFTER the dispatch comment
# cancels the lock early — the worker is done, re-dispatch is safe.
# Recognised completion signals: "TASK_COMPLETE", "FULL_LOOP_COMPLETE",
# "Worker failed", "BLOCKED", "Stale assignment recovered",
# "Kill signal sent", "gh pr merge", "Closes #".
#
# No active-claim-state gate (removed GH#17503) — the dispatch comment
# itself IS the claim. Labels and assignees are secondary signals.
#
# Args:
#   $1 = issue number
#   $2 = repo slug (owner/repo)
#   $3 = self login (unused; kept for backward compatibility — GH#15317)
# Returns:
#   exit 0 if a recent dispatch comment exists (do NOT dispatch)
#   exit 1 if no recent dispatch comment or superseded by completion (safe to dispatch)
# Outputs:
#   single-line reason when evidence is found
#######################################
has_dispatch_comment() {
	local issue_number="$1"
	local repo_slug="$2"
	# $3 = self_login — unused since GH#15317 (all dispatch comments checked regardless of author)

	if [[ ! "$issue_number" =~ ^[0-9]+$ ]] || [[ -z "$repo_slug" ]]; then
		return 1
	fi

	# GH#17503: No active-claim-state gate — dispatch comment IS the claim.
	# Removed the _get_active_claim_meta() check that required OPEN + assigned +
	# status:queued/in-progress. That gate allowed stale recovery to destroy the
	# claim state and bypass this check entirely.

	local max_age="${DISPATCH_COMMENT_MAX_AGE:-1800}" # 30 min (GH#17503, was 3600)
	local now_epoch
	now_epoch=$(date -u '+%s')

	# Fetch ALL comments — we need both dispatch and completion signals.
	# Extract type, author, and timestamp for each relevant comment.
	local comments_json
	comments_json=$(gh api "repos/${repo_slug}/issues/${issue_number}/comments" \
		--jq '[.[] | {
			body_start: (.body[:300]),
			author: .user.login,
			created_at: .created_at
		}]' \
		2>/dev/null) || comments_json="[]"

	if [[ -z "$comments_json" || "$comments_json" == "null" || "$comments_json" == "[]" ]]; then
		return 1
	fi

	# Find the most recent dispatch comment (newest first)
	local last_dispatch_json
	last_dispatch_json=$(printf '%s' "$comments_json" | jq -c '
		[.[] | select(.body_start | startswith("Dispatching worker"))]
		| sort_by(.created_at) | reverse | first // empty
	' 2>/dev/null) || last_dispatch_json=""

	if [[ -z "$last_dispatch_json" || "$last_dispatch_json" == "null" ]]; then
		return 1
	fi

	local dispatch_created_at dispatch_author
	dispatch_created_at=$(printf '%s' "$last_dispatch_json" | jq -r '.created_at // ""' 2>/dev/null) || dispatch_created_at=""
	dispatch_author=$(printf '%s' "$last_dispatch_json" | jq -r '.author // ""' 2>/dev/null) || dispatch_author=""

	# Check if the dispatch comment is within TTL
	if ! _is_dispatch_comment_active "$dispatch_created_at" "$dispatch_author" "$issue_number" "$now_epoch" "$max_age"; then
		return 1
	fi

	# GH#17503: Check for completion/failure comments posted AFTER the dispatch.
	# If found, the worker is done — the dispatch comment no longer blocks.
	local has_completion
	has_completion=$(printf '%s' "$comments_json" | jq -r --arg dispatch_ts "$dispatch_created_at" '
		[.[] | select(
			.created_at > $dispatch_ts and (
				(.body_start | test("TASK_COMPLETE"; "i")) or
				(.body_start | test("FULL_LOOP_COMPLETE"; "i")) or
				(.body_start | test("Worker failed"; "i")) or
				(.body_start | test("BLOCKED"; "i")) or
				(.body_start | test("Kill signal sent"; "i")) or
				(.body_start | test("Closes #"; "i")) or
				(.body_start | test("gh pr merge"; "i")) or
				(.body_start | test("MERGE_SUMMARY"; "i")) or
				(.body_start | test("Stale assignment recovered"; "i"))
			)
		)] | length
	' 2>/dev/null) || has_completion=0

	if [[ "$has_completion" -gt 0 ]]; then
		# Worker completed or failed — dispatch comment superseded, safe to re-dispatch
		return 1
	fi

	# Dispatch comment is active and not superseded — block re-dispatch
	return 0
}

#######################################
# Show help
#######################################
show_help() {
	cat <<'HELP'
dispatch-dedup-helper.sh - Normalize and deduplicate worker dispatch titles (t2310)

Usage:
  dispatch-dedup-helper.sh extract-keys <title>    Extract dedup keys from a title
  dispatch-dedup-helper.sh is-duplicate <title>     Check if already running (exit 0=dup, 1=safe)
  dispatch-dedup-helper.sh has-open-pr <issue> <slug> [issue-title]
                                                    Check merged PR evidence (exit 0=evidence, 1=none)
  dispatch-dedup-helper.sh has-dispatch-comment <issue> <slug> [self-login]
                                                     Check for recent "Dispatching worker" comment (exit 0=found, 1=none)
  dispatch-dedup-helper.sh is-assigned <issue> <slug> [self-login]
                                                       Check if assigned to another login (exit 0=blocked, 1=free)
  dispatch-dedup-helper.sh claim <issue> <slug> [runner-login]
                                                     Cross-machine claim lock (exit 0=won, 1=lost, 2=error)
  dispatch-dedup-helper.sh list-running-keys        List keys for all running workers
  dispatch-dedup-helper.sh normalize <title>        Normalize a title for comparison
  dispatch-dedup-helper.sh help                     Show this help

Examples:
  # Extract keys from various title formats
  dispatch-dedup-helper.sh extract-keys "Issue #2300: t1337 Simplify infra scripts"
  # Output: issue-2300
  #         task-t1337

  # Check before dispatching (local process dedup)
  if dispatch-dedup-helper.sh is-duplicate "Issue #2300: Fix auth"; then
    echo "Already running — skip dispatch"
  else
    echo "Safe to dispatch"
  fi

  # Check before dispatching (cross-machine assignee dedup — GH#11141)
  # Blocks if assigned to any login other than self
  if dispatch-dedup-helper.sh is-assigned 2300 owner/repo mylogin; then
    echo "Assigned to another login — skip dispatch"
  else
    echo "Unassigned or assigned to self — safe"
  fi

  # Check before dispatching (dispatch comment dedup — GH#11141)
  if dispatch-dedup-helper.sh has-dispatch-comment 2300 owner/repo mylogin; then
    echo "Another runner already dispatched — skip"
  else
    echo "No recent dispatch comment — safe"
  fi

  # Check before dispatching (merged PR dedup)
  if dispatch-dedup-helper.sh has-open-pr 2300 owner/repo "t2300: Fix auth"; then
    echo "Issue already has merged PR evidence — skip dispatch"
  else
    echo "No merged PR evidence — safe to dispatch"
  fi

  # Cross-machine claim lock (t1686)
  if dispatch-dedup-helper.sh claim 2300 owner/repo mylogin; then
    echo "Claim won — safe to dispatch"
    # ... dispatch worker ...
    # Claim comment persists as audit trail
  else
    echo "Claim lost or error — skip dispatch"
  fi
HELP
	return 0
}

#######################################
# Main
#######################################
main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	extract-keys)
		[[ $# -lt 1 ]] && {
			echo "Error: extract-keys requires a title argument" >&2
			return 1
		}
		extract_keys "$1"
		;;
	is-duplicate)
		[[ $# -lt 1 ]] && {
			echo "Error: is-duplicate requires a title argument" >&2
			return 1
		}
		is_duplicate "$1"
		;;
	is-assigned)
		[[ $# -lt 2 ]] && {
			echo "Error: is-assigned requires <issue-number> <repo-slug> [self-login]" >&2
			return 1
		}
		is_assigned "$1" "$2" "${3:-}"
		;;
	has-dispatch-comment)
		[[ $# -lt 2 ]] && {
			echo "Error: has-dispatch-comment requires <issue-number> <repo-slug> [self-login]" >&2
			return 1
		}
		has_dispatch_comment "$1" "$2" "${3:-}"
		;;
	has-open-pr)
		[[ $# -lt 2 ]] && {
			echo "Error: has-open-pr requires <issue-number> <repo-slug> [issue-title]" >&2
			return 1
		}
		has_open_pr "$1" "$2" "${3:-}"
		;;
	claim)
		[[ $# -lt 2 ]] && {
			echo "Error: claim requires <issue-number> <repo-slug> [runner-login]" >&2
			return 1
		}
		if [[ ! -x "$CLAIM_HELPER" ]]; then
			echo "Error: dispatch-claim-helper.sh not found at ${CLAIM_HELPER}" >&2
			return 2
		fi
		"$CLAIM_HELPER" claim "$1" "$2" "${3:-}"
		;;
	list-running-keys)
		list_running_keys
		;;
	normalize)
		[[ $# -lt 1 ]] && {
			echo "Error: normalize requires a title argument" >&2
			return 1
		}
		normalize_title "$1"
		;;
	help | --help | -h)
		show_help
		;;
	*)
		echo "Error: Unknown command: $command" >&2
		show_help
		return 1
		;;
	esac
}

main "$@"
