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
	local branch_issue_nums
	branch_issue_nums=$(printf '%s' "$lower_title" | grep -oE 'issue-([0-9]+)' | grep -oE '[0-9]+' || true)
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
	local worker_procs
	# Get full command lines of running worker processes
	# macOS ps -eo pid,args works; Linux ps -eo pid,args works too
	# shellcheck disable=SC2009  # Need ps+grep for full cmdline; pgrep can't return args
	worker_procs=$(ps -eo pid,args 2>/dev/null | grep -E '/full-loop|opencode run|claude.*run' | grep -v grep || true)

	if [[ -z "$worker_procs" ]]; then
		return 0
	fi

	while IFS= read -r proc_line; do
		[[ -z "$proc_line" ]] && continue
		local pid
		pid=$(printf '%s' "$proc_line" | awk '{print $1}')
		local cmdline
		cmdline=$(printf '%s' "$proc_line" | sed 's/^[[:space:]]*[0-9]*[[:space:]]*//')

		local keys
		keys=$(extract_keys "$cmdline")
		if [[ -n "$keys" ]]; then
			while IFS= read -r key; do
				[[ -n "$key" ]] && printf '%s|%s\n' "$pid" "$key"
			done <<<"$keys"
		fi
	done <<<"$worker_procs"

	return 0
}

#######################################
# Check if a title's dedup keys overlap with any running worker.
# Args: $1 = title of the item to be dispatched
# Returns: exit 0 if duplicate found (do NOT dispatch),
#          exit 1 if no duplicate (safe to dispatch)
# Outputs: matching key and PID on stdout if duplicate found
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

	# Get keys from running workers
	local running_keys
	running_keys=$(list_running_keys)

	if [[ -z "$running_keys" ]]; then
		# No running workers — no duplicate possible
		return 1
	fi

	# Check for overlap (with cross-type matching: ref-NNN matches issue-NNN and pr-NNN)
	while IFS= read -r candidate_key; do
		[[ -z "$candidate_key" ]] && continue

		# Build list of patterns to match against
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
	done <<<"$candidate_keys"

	# Also check the supervisor DB if available
	local supervisor_db="${SUPERVISOR_DIR:-${HOME}/.aidevops/.agent-workspace/supervisor}/supervisor.db"
	if [[ -f "$supervisor_db" ]] && command -v sqlite3 &>/dev/null; then
		while IFS= read -r candidate_key; do
			[[ -z "$candidate_key" ]] && continue
			# Extract the number from the key for DB lookup
			local key_type key_num
			key_type=$(printf '%s' "$candidate_key" | cut -d'-' -f1)
			key_num=$(printf '%s' "$candidate_key" | cut -d'-' -f2-)

			local db_match=""
			case "$key_type" in
			issue)
				# Check if any running/dispatched task references this issue number
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
				# Check if this task ID is already active
				db_match=$(sqlite3 "$supervisor_db" "
					SELECT id FROM tasks
					WHERE status IN ('running', 'dispatched', 'evaluating')
					AND id = '${key_num}'
					LIMIT 1;
				" 2>/dev/null || true)
				;;
			pr)
				# Check if any running task references this PR number
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

			if [[ -n "$db_match" ]]; then
				printf 'DUPLICATE: key=%s already active in supervisor DB (task %s)\n' "$candidate_key" "$db_match"
				return 0
			fi
		done <<<"$candidate_keys"
	fi

	# No duplicates found
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
  dispatch-dedup-helper.sh list-running-keys        List keys for all running workers
  dispatch-dedup-helper.sh normalize <title>        Normalize a title for comparison
  dispatch-dedup-helper.sh help                     Show this help

Examples:
  # Extract keys from various title formats
  dispatch-dedup-helper.sh extract-keys "Issue #2300: t1337 Simplify infra scripts"
  # Output: issue-2300
  #         task-t1337

  # Check before dispatching
  if dispatch-dedup-helper.sh is-duplicate "Issue #2300: Fix auth"; then
    echo "Already running — skip dispatch"
  else
    echo "Safe to dispatch"
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
