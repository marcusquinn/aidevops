#!/usr/bin/env bash
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
#   dispatch-dedup-helper.sh list-running-keys
#     List dedup keys for all currently running workers.
#
#   dispatch-dedup-helper.sh normalize <title>
#     Return the normalized (lowercased, stripped) form of a title for comparison.

set -euo pipefail

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
# Check if a GitHub issue is already assigned to someone else.
#
# This is the primary cross-machine dedup guard. Process-based checks
# (is_duplicate, has_worker_for_repo_issue) only see local processes —
# they miss workers running on other machines. The GitHub assignee is
# the single source of truth visible to all runners.
#
# Args:
#   $1 = issue number
#   $2 = repo slug (owner/repo)
#   $3 = (optional) current runner login — if assigned to self, not a dup
# Returns:
#   exit 0 if assigned to someone else (do NOT dispatch)
#   exit 1 if unassigned or assigned to self (safe to dispatch)
# Outputs: assignee info on stdout if assigned
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

	# Query GitHub for current assignees
	local assignees
	assignees=$(gh issue view "$issue_number" --repo "$repo_slug" \
		--json assignees --jq '[.assignees[].login] | join(",")' 2>/dev/null) || assignees=""

	if [[ -z "$assignees" ]]; then
		# No assignees — safe to dispatch
		return 1
	fi

	# If assigned to self, not a duplicate
	if [[ -n "$self_login" ]]; then
		# Check if ALL assignees are self (could be multiple)
		local dominated_by_self=true
		local -a assignee_array=()
		local saved_ifs="${IFS:-}"
		IFS=',' read -ra assignee_array <<<"$assignees"
		IFS="$saved_ifs"
		local assignee
		for assignee in "${assignee_array[@]}"; do
			if [[ "$assignee" != "$self_login" ]]; then
				dominated_by_self=false
				break
			fi
		done
		if [[ "$dominated_by_self" == "true" ]]; then
			return 1
		fi
	fi

	printf 'ASSIGNED: issue #%s in %s is assigned to %s\n' "$issue_number" "$repo_slug" "$assignees"
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
  dispatch-dedup-helper.sh is-assigned <issue> <slug> [self-login]
                                                    Check if issue is assigned (exit 0=assigned, 1=free)
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

  # Check before dispatching (cross-machine assignee dedup)
  if dispatch-dedup-helper.sh is-assigned 2300 owner/repo mylogin; then
    echo "Assigned to someone else — skip dispatch"
  else
    echo "Unassigned or assigned to self — safe to dispatch"
  fi

  # Check before dispatching (merged PR dedup)
  if dispatch-dedup-helper.sh has-open-pr 2300 owner/repo "t2300: Fix auth"; then
    echo "Issue already has merged PR evidence — skip dispatch"
  else
    echo "No merged PR evidence — safe to dispatch"
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
	has-open-pr)
		[[ $# -lt 2 ]] && {
			echo "Error: has-open-pr requires <issue-number> <repo-slug> [issue-title]" >&2
			return 1
		}
		has_open_pr "$1" "$2" "${3:-}"
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
