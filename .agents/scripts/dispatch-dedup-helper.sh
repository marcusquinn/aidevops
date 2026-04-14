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

# t2033: source shared-constants for set_issue_status helper. Include guard
# inside shared-constants.sh makes this safe even when orchestrator already
# sourced it.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh"

# GH#18917: cost circuit breaker extracted to keep this file below 2000 lines.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/dispatch-dedup-cost.sh"

# GH#18916: stale assignment recovery subsystem extracted.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/dispatch-dedup-stale.sh"

# GH#18916: PR evidence dedup checks extracted.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/dispatch-dedup-pr.sh"

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
#
# t2061 audit (2026-04-14):
#
# Error path classification for _check_db_entry:
#
#   sqlite3 DB unavailable (missing file, access error):
#     → 2>/dev/null || true swallows the error → db_match="" → return 1
#     → FAIL-OPEN INTENTIONAL: missing DB = no prior dispatch claim entry.
#       The correct answer to "is this a duplicate?" when the DB is absent is
#       "no" — genuine duplicates have DB entries; absence is evidence of absence.
#
#   sqlite3 query error (permission, corruption, format mismatch):
#     → 2>/dev/null || true → db_match="" → return 1
#     → FAIL-OPEN INTENTIONAL: same rationale. Cannot confirm a claim we
#       cannot read; the safe assumption is no prior claim.
#
#   PID file read error (unreadable, missing):
#     → cat 2>/dev/null || true → stored_pid="" → "No valid PID file" branch
#     → stale → return 1 (safe to dispatch)
#     → FAIL-OPEN INTENTIONAL: cannot prove liveness without the PID. The
#       GH#5662 design intent is to recover stale entries; unreadable PID
#       files match the stale criteria.
#
#   sqlite3 UPDATE error during stale cleanup:
#     → 2>/dev/null || true → cleanup silently fails → return 1 (stale)
#     → FAIL-OPEN INTENTIONAL: cleanup failure does not affect the dispatch
#       decision. The dispatch is already allowed; cleanup is housekeeping.
#
# All fail-open paths answer "is this a duplicate?" with "no", which is the
# safest default for this guard. A genuine duplicate has a live DB entry;
# absence or unreadability is not evidence of a claim.
# NOTE: this is a LOCAL-ONLY guard (this machine's supervisor DB only).
# The cross-machine guard (is_assigned) enforces GUARD_UNCERTAIN fail-closed.
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
#
# t2061 audit (2026-04-14):
#
# Error path classification for is_duplicate:
#
#   extract_keys failure or empty output:
#     → candidate_keys="" → [[ -z ]] branch → return 1 (allow dispatch)
#     → FAIL-OPEN INTENTIONAL: cannot deduplicate without keys. Dispatch
#       is allowed to avoid permanently blocking any title that can't be
#       parsed. The cross-machine is_assigned() guard is the safety net.
#
#   list_running_keys failure or empty output:
#     → running_keys="" → process-match loop not entered → proceed to DB check
#     → FAIL-OPEN INTENTIONAL: no running keys = no running duplicates on
#       this machine. This check is local-only; is_assigned() covers cross-machine.
#
#   _check_db_entry failures:
#     → return 1 (no duplicate found) — see _check_db_entry audit above.
#     → FAIL-OPEN INTENTIONAL: same rationale as _check_db_entry.
#
#   sqlite3 unavailable:
#     → `command -v sqlite3` gate → DB check skipped entirely → return 1
#     → FAIL-OPEN INTENTIONAL: cannot use a tool that is not installed.
#
# is_duplicate is a LOCAL-ONLY guard (running processes + supervisor DB on
# this machine only). It complements but does not replace is_assigned().
# Fail-open is appropriate because is_assigned() is the definitive
# cross-machine guard with GUARD_UNCERTAIN fail-closed semantics (t2046).
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

# Stale assignment recovery functions are in dispatch-dedup-stale.sh (GH#18916).

#######################################
# Return "true" if the issue metadata represents an active claim that
# should override the owner/maintainer passive-assignee exemption in
# is_assigned(). An issue is actively claimed when EITHER:
#   - a lifecycle status label is set: status:queued, status:in-progress,
#     status:in-review, or status:claimed, OR
#   - the origin:interactive label is present (a live human session is
#     driving the work regardless of status label state)
#
# Extracted from is_assigned() to keep that function under the 100-line
# complexity cap after GH#18352 expanded the active-claim signal set
# (see t1961). Adding new active-state labels is a one-line change here.
#
# Canonical dedup rule (t1996):
#   The dispatch dedup signal is (active status label) AND (non-self assignee).
#   Both are required; neither alone is sufficient:
#   - Label without assignee = degraded state (safe to reclaim after stale recovery)
#   - Assignee without active label = passive backlog bookkeeping (owner/maintainer
#     passive exemption applies; non-owner/maintainer still blocks)
#   - Label WITH non-self assignee = active claim (always blocks)
#   This function evaluates only the label half. is_assigned() enforces the
#   combined check by calling this only after an assignee is confirmed present.
#
# Args:
#   $1 = issue metadata JSON from `gh issue view --json labels` (at minimum
#        must contain a .labels array of {name: ...} objects)
# Stdout: "true" or "false"
#######################################
_has_active_claim() {
	local issue_meta_json="$1"
	local result
	result=$(printf '%s' "$issue_meta_json" | jq -r '
		.labels? // [] | any(.[].name; . == "status:queued" or . == "status:in-progress" or . == "status:in-review" or . == "status:claimed" or . == "origin:interactive")
	' 2>/dev/null) || result="false"
	[[ "$result" == "true" || "$result" == "false" ]] || result="false"
	printf '%s' "$result"
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
# Canonical dedup rule (t1996):
#   The dispatch dedup signal is (active status label) AND (non-self assignee).
#   Both are required; neither alone is sufficient.
#   See _has_active_claim() for the label-half definition.
#   This function enforces the combined check: it first checks whether an
#   assignee is present; if so, it calls _has_active_claim() to determine
#   if the passive exemption for owner/maintainer should be bypassed.
#
# Systemic rule:
# - self_login never blocks
# - owner/maintainer assignees are passive unless EITHER:
#     (a) the issue has an active claim status label — status:queued,
#         status:in-progress, status:in-review, or status:claimed
#         (full active lifecycle, not just the worker-set states), OR
#     (b) the issue has the origin:interactive label — a human session
#         is actively driving the work regardless of status label state
#         (GH#18352 — closes the race where an interactive claim used
#         status:claimed, which was not recognised as an active state,
#         so the pulse dispatched a duplicate worker mid-flight)
# - any other assignee blocks dispatch — UNLESS the assignment is stale
#   (no active worker, dispatch claim >1h old, no recent progress).
#   Stale assignments are auto-recovered (GH#15060).
#
# Every dispatch decision site that emits a worker assignment MUST route
# through this function (or apply an equivalent inline combined check)
# before claiming. Any code path that checks only labels or only assignees
# is not safe in multi-operator conditions. (t1996 — audit confirmed that
# dispatch_with_dedup, apply_deterministic_fill_floor, and all implementation
# dispatch paths correctly route through check_dispatch_dedup which calls
# this function at Layer 6; normalize_active_issue_assignments was hardened
# in the same fix to also call this before self-assigning orphaned issues.)
#
# This preserves GH#10521 (maintainer assignment alone must not starve the
# queue) while still protecting GH#11141 (owner-assigned queued work must
# block other runners once a real claim is active) and GH#18352 (interactive
# sessions working on owner-assigned issues must not be raced by the pulse).
#
# Args:
#   $1 = issue number
#   $2 = repo slug (owner/repo)
#   $3 = (optional) current runner login — if assigned to self, not a dup
# Returns:
#   exit 0 if assigned to another login (do NOT dispatch), parent-task labeled,
#          cost-budget exceeded, or guard cannot determine safety (GUARD_UNCERTAIN)
#   exit 1 if unassigned or assigned only to self (safe to dispatch)
# Outputs: one of the following signals on stdout when blocking:
#   PARENT_TASK_BLOCKED (label=<name>) — unconditional parent-task block
#   COST_BUDGET_EXCEEDED (...)         — token spend circuit breaker
#   GUARD_UNCERTAIN (reason=...)       — internal error, cannot determine safety
#   <assignee info>                    — active claim by another runner
#
# FAIL-CLOSED CONTRACT (t2046):
#   When the guard cannot determine whether dispatch is safe due to an internal
#   error (gh API failure, jq error, helper failure), the function MUST block
#   dispatch and emit GUARD_UNCERTAIN. This is intentionally conservative:
#   a transient block clears in the next pulse cycle at zero cost; a wasted
#   worker dispatch burns ~20K tokens for zero output (GH#18458 incident).
#   The previous default (fail-open) allowed three workers to be dispatched
#   to a parent-task issue because a jq null-handling bug silently fell through
#   to the "allow dispatch" code path (see plan in todo/plans/parent-task-incident-hardening.md).
#######################################
#######################################
# is_assigned helper: check the parent-task / meta unconditional block.
#
# t1986: parent-task / meta label is an unconditional dispatch block.
# Any issue tagged as parent-only is plan-only work and must never
# receive a dispatched worker, regardless of assignees or status
# labels. Closes the dispatch loop observed on GH#18356 during
# t1962 Phase 3 (parent task dispatched twice with opus-4-6,
# burning ~20K tokens for zero productive output) and the
# same race reproduced on GH#18399 / GH#18400 while filing the
# follow-up issues for this very fix.
#
# Emits PARENT_TASK_BLOCKED on stdout for caller pattern matching
# (mirrors the STALE_RECOVERED token used by stale-recovery path).
#
# t2061: explicit jq failure capture — fail-closed. A jq failure here
# (type error, compile error, malformed labels field) would previously
# fall through to "no parent-task label found" via the || true pattern,
# silently skipping the unconditional dispatch block. Now emits
# GUARD_UNCERTAIN on any internal jq failure.
#
# Args:
#   $1 = issue metadata JSON (from `gh issue view --json ...,labels`)
#   $2 = (optional) issue number — included in GUARD_UNCERTAIN output
#   $3 = (optional) repo slug — included in GUARD_UNCERTAIN output
# Returns: exit 0 if parent-task label found or jq fails (prints signal),
#          exit 1 if no parent-task label and jq succeeds
#######################################
_is_assigned_check_parent_task() {
	local meta_json="$1"
	local issue_number="${2:-unknown}"
	local repo_slug="${3:-unknown}"
	# t2061: explicit rc capture — fail-closed on jq failure.
	local _jq_rc=0
	local parent_task_hit
	parent_task_hit=$(printf '%s' "$meta_json" |
		jq -r '(.labels // [])[].name | select(. == "parent-task" or . == "meta")' 2>/dev/null | head -n 1) || _jq_rc=$?
	if [[ "$_jq_rc" -ne 0 ]]; then
		printf 'GUARD_UNCERTAIN (reason=jq-failure call=parent-task-check issue=%s repo=%s)\n' \
			"$issue_number" "$repo_slug"
		return 0
	fi
	if [[ -n "$parent_task_hit" ]]; then
		printf 'PARENT_TASK_BLOCKED (label=%s)\n' "$parent_task_hit"
		return 0
	fi
	return 1
}

#######################################
# is_assigned helper: cost-per-issue circuit breaker (t2007).
#
# Aggregate token spend across all worker attempts; if the cumulative total
# exceeds the tier-appropriate budget, apply needs-maintainer-review and
# block dispatch. Fail-open on aggregation errors so unrelated GitHub API
# hiccups don't starve the queue. Closes the cost-runaway hole that t1986
# (parent-task guard) and t2008 (stale-recovery escalation) leave open: an
# issue with a correct tier assignment that workers can never finish
# (loop, hidden blocker, scope).
#
# Args: $1 = issue number, $2 = repo slug, $3 = issue metadata JSON
# Returns: exit 0 if budget tripped (prints signal), exit 1 if under budget
#######################################
_is_assigned_check_cost_budget() {
	local issue_number="$1"
	local repo_slug="$2"
	local meta_json="$3"

	local _t2007_tier
	_t2007_tier=$(printf '%s' "$meta_json" |
		jq -r '[(.labels // [])[].name] | map(select(startswith("tier:"))) | .[0] // "tier:standard"' 2>/dev/null)
	[[ -z "$_t2007_tier" || "$_t2007_tier" == "null" ]] && _t2007_tier="tier:standard"

	local _t2007_signal _t2007_rc=0
	_t2007_signal=$(_check_cost_budget "$issue_number" "$repo_slug" "$_t2007_tier" "$meta_json") || _t2007_rc=$?
	if [[ "$_t2007_rc" -eq 0 ]]; then
		printf '%s\n' "$_t2007_signal"
		return 0
	fi
	return 1
}

#######################################
# is_assigned helper: compute the blocking assignees set.
#
# Walks the assignees list and filters out:
#   - self_login when there is NO active claim (passive bookkeeping)
#   - owner/maintainer if no active claim state (GH#18352 / t1961)
#
# Owner/maintainer is passive UNLESS _has_active_claim returned "true".
# See _has_active_claim() for the full rule set.
#
# The self_login exemption is intentionally bypassed when active_claim
# is "true". In a single-user setup the interactive user and the pulse
# runner share the same GitHub login. Without this exception the pulse
# skips the assignee (it looks like self) and ignores origin:interactive,
# dispatching a duplicate worker. The exemption exists to prevent a runner
# from blocking its own re-dispatch on a passively-bookmarked issue — that
# use-case has no active claim label, so the guard is still satisfied.
# (GH#18956 incident root cause — fixed in t2091.)
#
# Args:
#   $1 = assignees (comma-separated login list)
#   $2 = repo_owner
#   $3 = repo_maintainer (may be empty)
#   $4 = active_claim ("true" or other)
#   $5 = self_login (may be empty)
# Output: comma-separated list of blocking assignees on stdout (may be empty)
#######################################
_is_assigned_compute_blocking() {
	local assignees="$1"
	local repo_owner="$2"
	local repo_maintainer="$3"
	local active_claim="$4"
	local self_login="$5"

	local -a assignee_array=()
	local saved_ifs="${IFS:-}"
	IFS=',' read -ra assignee_array <<<"$assignees"
	IFS="$saved_ifs"

	local blocking_assignees=""
	local assignee
	for assignee in "${assignee_array[@]}"; do
		# Self-login is passive UNLESS an active claim exists. When active_claim
		# is "true" (status label OR origin:interactive), the assignment is
		# intentional — skip the self-login exemption so the issue blocks
		# re-dispatch even in single-user setups. (t2091)
		if [[ -n "$self_login" && "$assignee" == "$self_login" && "$active_claim" != "true" ]]; then
			continue
		fi

		if [[ "$assignee" == "$repo_owner" || (-n "$repo_maintainer" && "$assignee" == "$repo_maintainer") ]]; then
			# Owner/maintainer is passive UNLESS _has_active_claim returned
			# "true" (GH#18352 / t1961).
			if [[ "$active_claim" != "true" ]]; then
				continue
			fi
		fi

		if [[ -n "$blocking_assignees" ]]; then
			blocking_assignees="${blocking_assignees},${assignee}"
		else
			blocking_assignees="$assignee"
		fi
	done
	printf '%s' "$blocking_assignees"
	return 0
}

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

	local issue_meta_json gh_rc=0
	issue_meta_json=$(gh issue view "$issue_number" --repo "$repo_slug" \
		--json state,assignees,labels 2>/dev/null) || gh_rc=$?

	# t2046: fail-closed on gh API failure. When we cannot fetch issue metadata
	# (network error, auth failure, rate limit, issue not found), we cannot
	# determine whether dispatch is safe. Block and emit GUARD_UNCERTAIN so the
	# pulse skips this cycle rather than dispatching blindly.
	if [[ "$gh_rc" -ne 0 || -z "$issue_meta_json" ]]; then
		printf 'GUARD_UNCERTAIN (reason=gh-api-failure issue=%s repo=%s rc=%s)\n' \
			"$issue_number" "$repo_slug" "$gh_rc"
		return 0
	fi

	# t1986: parent-task / meta is an unconditional dispatch block.
	# t2061: pass issue_number + repo_slug so GUARD_UNCERTAIN output is traceable.
	if _is_assigned_check_parent_task "$issue_meta_json" "$issue_number" "$repo_slug"; then
		return 0
	fi

	# t2007: cost-per-issue circuit breaker.
	if _is_assigned_check_cost_budget "$issue_number" "$repo_slug" "$issue_meta_json"; then
		return 0
	fi

	# Query GitHub for current assignees.
	# t2061: explicit jq rc capture — fail-closed.
	# A jq failure here (e.g. assignees field has unexpected type) would previously
	# set assignees="" → "No assignees — safe to dispatch", bypassing the assignee
	# guard entirely. GUARD_UNCERTAIN instead.
	local _jq_assignees_rc=0
	local assignees
	assignees=$(printf '%s' "$issue_meta_json" | jq -r '[.assignees[].login] | join(",")' 2>/dev/null) || _jq_assignees_rc=$?
	if [[ "$_jq_assignees_rc" -ne 0 ]]; then
		printf 'GUARD_UNCERTAIN (reason=jq-failure call=assignees-extract issue=%s repo=%s)\n' \
			"$issue_number" "$repo_slug"
		return 0
	fi

	if [[ -z "$assignees" ]]; then
		# No assignees — safe to dispatch
		return 1
	fi

	local repo_owner repo_maintainer
	repo_owner=$(_get_repo_owner "$repo_slug")
	repo_maintainer=$(_get_repo_maintainer "$repo_slug")
	# GH#18352 / t1961: owner/maintainer assignees are passive unless
	# _has_active_claim() reports an active lifecycle label (queued,
	# in-progress, in-review, claimed) or origin:interactive is present.
	# See _has_active_claim() above for the full rule set.
	# t2061: explicit helper rc capture — fail-closed.
	# _has_active_claim normalises output to "true"/"false" and always exits 0,
	# but explicit capture documents the contract and protects against future changes.
	local _hac_rc=0
	local active_claim
	active_claim=$(_has_active_claim "$issue_meta_json") || _hac_rc=$?
	if [[ "$_hac_rc" -ne 0 ]]; then
		printf 'GUARD_UNCERTAIN (reason=helper-failure call=_has_active_claim issue=%s repo=%s)\n' \
			"$issue_number" "$repo_slug"
		return 0
	fi

	local blocking_assignees
	blocking_assignees=$(_is_assigned_compute_blocking \
		"$assignees" "$repo_owner" "$repo_maintainer" "$active_claim" "$self_login")

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

# PR evidence dedup check functions are in dispatch-dedup-pr.sh (GH#18916).

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
#
# t2061 audit (2026-04-14):
#
# Error path classification for _is_dispatch_comment_active:
#
#   empty created_at ($1):
#     → [[ -z "$created_at" ]] → return 1 (allow dispatch)
#     → FAIL-OPEN INTENTIONAL: no timestamp = no comment to evaluate.
#
#   date parsing failure (both GNU and macOS date variants fail):
#     → comment_epoch set to "0" (printf '0' fallback in the || chain)
#     → age = now_epoch - 0 = very large number → age >= max_age → return 1
#     → FAIL-OPEN INTENTIONAL: unreadable timestamp cannot prove recency.
#       Defaulting to "expired" avoids permanently blocking dispatch on
#       malformed or unrecognised timestamp formats. The TTL design
#       (default 10 min) means blocks are always temporary; unreadable
#       timestamps should not create permanent blocks.
#
#   No jq calls in this function. jq is used in the calling function
#   has_dispatch_comment() which handles its own jq failures with || fallbacks.
#   See has_dispatch_comment() for its error handling.
#
# Summary: this function is a pure TTL-comparison check on a single comment.
# Fail-open on timestamp parse failures is appropriate because: (a) TTLs are
# already conservative (10 min), (b) permanent blocks from bad timestamps
# cause deadlock, and (c) this is a secondary guard — is_assigned() is the
# primary cross-machine dedup guard with GUARD_UNCERTAIN fail-closed behavior.
# ALREADY CONFIRMED FAIL-OPEN BY DESIGN — no hardening needed (t2061).
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
# DISPATCH_COMMENT_MAX_AGE seconds (default 600 = 10 min). After that,
# the comment stays for audit but no longer blocks — allowing a fresh
# dispatch attempt.
#
# A completion or failure comment posted AFTER the dispatch comment
# cancels the lock early — the worker is done, re-dispatch is safe.
# Recognised completion signals: "TASK_COMPLETE", "FULL_LOOP_COMPLETE",
# "Worker failed", "Worker Watchdog Kill", "BLOCKED",
# "Stale assignment recovered", "Kill signal sent", "gh pr merge",
# "Closes #", "MERGE_SUMMARY", "CLAIM_RELEASED".
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
	# Active-claim pre-gate was removed: it required OPEN + assigned +
	# status:queued/in-progress, but stale recovery could destroy that state and
	# bypass this check entirely.

	local max_age="${DISPATCH_COMMENT_MAX_AGE:-600}" # 10 min (was 30 min/1800s — reduced to match worker lifecycle; crash recovery was wasting 28 min per crash)
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
				(.body_start | test("Worker Watchdog Kill"; "i")) or
				(.body_start | test("BLOCKED"; "i")) or
				(.body_start | test("Kill signal sent"; "i")) or
				(.body_start | test("Closes #"; "i")) or
				(.body_start | test("gh pr merge"; "i")) or
				(.body_start | test("MERGE_SUMMARY"; "i")) or
				(.body_start | test("Stale assignment recovered"; "i")) or
			(.body_start | test("CLAIM_RELEASED"; "i"))
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
# Validate subcommand arg count. Used by main() to collapse the repeated
# "[[ $# -lt N ]] && { echo Error; return 1; }" pattern into a single call.
# Args:
#   $1 = subcommand name (for error message)
#   $2 = required arg count
#   $3 = provided arg count (typically "$#")
#   $4 = usage hint (e.g., "<issue-number> <repo-slug>")
# Returns: 0 if enough args, 1 otherwise (and prints error to stderr)
#######################################
_require_args() {
	local cmd="$1"
	local required="$2"
	local provided="$3"
	local usage="$4"
	if [[ "$provided" -lt "$required" ]]; then
		echo "Error: ${cmd} requires ${usage}" >&2
		return 1
	fi
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
  dispatch-dedup-helper.sh check-cost-budget <issue> <slug> [tier]
                                                       t2007: cost circuit breaker (exit 0=tripped, 1=under budget)
  dispatch-dedup-helper.sh sum-issue-token-spend <issue> <slug>
                                                       t2007: aggregate token spend (returns "spent|attempts")
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
		_require_args extract-keys 1 "$#" "a title argument" || return 1
		extract_keys "$1"
		;;
	is-duplicate)
		_require_args is-duplicate 1 "$#" "a title argument" || return 1
		is_duplicate "$1"
		;;
	is-assigned)
		_require_args is-assigned 2 "$#" "<issue-number> <repo-slug> [self-login]" || return 1
		is_assigned "$1" "$2" "${3:-}"
		;;
	check-cost-budget)
		# t2007: cost-per-issue circuit breaker. Direct entry point for tests
		# and ad-hoc inspection. The same check fires inline from is-assigned.
		_require_args check-cost-budget 2 "$#" "<issue-number> <repo-slug> [tier]" || return 1
		_check_cost_budget "$1" "$2" "${3:-standard}"
		;;
	sum-issue-token-spend)
		# t2007: read-only aggregator (no side effects). Useful for calibration.
		_require_args sum-issue-token-spend 2 "$#" "<issue-number> <repo-slug>" || return 1
		_sum_issue_token_spend "$1" "$2"
		;;
	has-dispatch-comment)
		_require_args has-dispatch-comment 2 "$#" "<issue-number> <repo-slug> [self-login]" || return 1
		has_dispatch_comment "$1" "$2" "${3:-}"
		;;
	has-open-pr)
		_require_args has-open-pr 2 "$#" "<issue-number> <repo-slug> [issue-title]" || return 1
		has_open_pr "$1" "$2" "${3:-}"
		;;
	claim)
		_require_args claim 2 "$#" "<issue-number> <repo-slug> [runner-login]" || return 1
		if [[ ! -x "$CLAIM_HELPER" ]]; then
			echo "Error: dispatch-claim-helper.sh not found at ${CLAIM_HELPER}" >&2
			return 2
		fi
		"$CLAIM_HELPER" claim "$1" "$2" "${3:-}"
		;;
	check-claim)
		# GH#17590: Pre-check for active claims (read-only, no comment posted).
		_require_args check-claim 2 "$#" "<issue-number> <repo-slug>" || return 1
		if [[ ! -x "$CLAIM_HELPER" ]]; then
			echo "Error: dispatch-claim-helper.sh not found at ${CLAIM_HELPER}" >&2
			return 2
		fi
		"$CLAIM_HELPER" check "$1" "$2"
		;;
	list-running-keys)
		list_running_keys
		;;
	normalize)
		_require_args normalize 1 "$#" "a title argument" || return 1
		normalize_title "$1"
		;;
	test-recover)
		# Test shim for t2008: expose _recover_stale_assignment for test harness.
		# Usage: dispatch-dedup-helper.sh test-recover <issue> <repo> <assignees> <reason>
		# Not for production use — test files only.
		_require_args test-recover 4 "$#" "<issue> <repo> <assignees> <reason>" || return 1
		_recover_stale_assignment "$1" "$2" "$3" "$4"
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
