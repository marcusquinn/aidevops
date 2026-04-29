#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# orphan-worker-reaper.sh — Detects and reattaches orphaned worker processes
#   that survived a pulse-wrapper.sh crash or restart.
#
# Workers are launched with `setsid nohup ... &` via _dlw_exec_detached()
# (pulse-dispatch-worker-launch.sh:421). They intentionally survive pulse
# death per the t2814 setsid isolation design — the worker PGID differs from
# the pulse PGID so a pulse SIGTERM does not cascade to workers.
#
# On pulse crash, running workers lose their dispatch ledger entry — they
# continue running but are invisible to the new pulse instance (no ledger
# entry, no watchdog, no reap-on-completion). These are "orphan workers".
#
# This module is sourced by pulse-wrapper.sh and provides reap_orphan_workers()
# which is called once per cycle in _pulse_run_deterministic_pipeline().
#
# Functions (public):
#   reap_orphan_workers()              — main entry point, called every cycle
#
# Functions (private):
#   _reaper_extract_issue()            — extract issue number from cmd line
#   _reaper_extract_session_key()      — extract --session-key from cmd line
#   _reaper_extract_dir()              — extract --dir path from cmd line
#   _reaper_repo_slug_from_dir()       — derive owner/repo from worktree dir
#   _reaper_classify_and_act()         — per-worker classification + action
#   _reaper_post_recovery_comment()    — post ORPHAN_REATTACHED audit comment
#   _reaper_kill_stuck_orphan()        — kill + post ORPHAN_STUCK_KILLED comment
#
# Dependencies (expected to be sourced by pulse-wrapper.sh before this file):
#   - shared-constants.sh (LOGFILE)
#   - worker-lifecycle-common.sh (list_active_worker_processes, _get_process_age,
#                                  _kill_tree, _force_kill_tree)
#   - dispatch-ledger-helper.sh (external binary via SCRIPT_DIR)
#
# GH#21604 / t3035

# Include guard — prevent double-sourcing.
[[ -n "${_ORPHAN_WORKER_REAPER_LOADED:-}" ]] && return 0
_ORPHAN_WORKER_REAPER_LOADED=1

# ---------------------------------------------------------------------------
# Configuration (overridable via env vars)
# ---------------------------------------------------------------------------
# Workers younger than this (seconds) are not candidates — they may be in the
# registration window (stagger delay is 8s, so 60s is a safe margin).
ORPHAN_REAPER_MIN_AGE_S="${ORPHAN_REAPER_MIN_AGE_S:-60}"
# Workers running longer than this (seconds) with no ledger entry are stuck;
# kill them rather than reattaching. Default: 2h (7200s) matches ORPHAN_MAX_AGE.
ORPHAN_REAPER_STUCK_AGE_S="${ORPHAN_REAPER_STUCK_AGE_S:-7200}"
# Set to 0 to disable the reaper entirely (e.g. during debugging).
ORPHAN_REAPER_ENABLED="${ORPHAN_REAPER_ENABLED:-1}"

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

#######################################
# Extract the GitHub issue number from a worker process command line.
# Matches --session-key issue-NNN (primary) or "issue-NNN" anywhere (fallback).
#
# Args:
#   $1 - full command line string from ps output
# Output: issue number (digits only) on stdout, empty if not found
#######################################
_reaper_extract_issue() {
	local cmd_line="$1"
	local issue=""

	# Primary: --session-key issue-NNN
	issue=$(printf '%s' "$cmd_line" | \
		sed -n 's/.*--session-key[[:space:]]\{1,\}issue-\([0-9]\{1,\}\).*/\1/p')

	# Fallback: issue-NNN anywhere else in the line
	if [[ -z "$issue" ]]; then
		issue=$(printf '%s' "$cmd_line" | \
			sed -n 's/.*issue-\([0-9]\{1,\}\).*/\1/p' | head -1)
	fi

	printf '%s' "$issue"
	return 0
}

#######################################
# Extract the --session-key value from a worker process command line.
#
# Args:
#   $1 - full command line string from ps output
# Output: session key on stdout, empty if not found
#######################################
_reaper_extract_session_key() {
	local cmd_line="$1"
	local sk=""

	sk=$(printf '%s' "$cmd_line" | \
		sed -n 's/.*--session-key[[:space:]]\{1,\}\([^[:space:]]\{1,\}\).*/\1/p')

	printf '%s' "$sk"
	return 0
}

#######################################
# Extract the --dir path from a worker process command line.
#
# Args:
#   $1 - full command line string from ps output
# Output: worktree directory path on stdout, empty if not found
#######################################
_reaper_extract_dir() {
	local cmd_line="$1"
	local dir=""

	dir=$(printf '%s' "$cmd_line" | \
		sed -n 's/.*--dir[[:space:]]\{1,\}\([^[:space:]]\{1,\}\).*/\1/p')

	printf '%s' "$dir"
	return 0
}

#######################################
# Derive the owner/repo slug from a git worktree directory path.
#
# Args:
#   $1 - absolute path to worktree directory
# Output: "owner/repo" slug on stdout, empty on failure
#######################################
_reaper_repo_slug_from_dir() {
	local dir="$1"
	local slug=""

	[[ -n "$dir" && -d "$dir" ]] || return 0

	slug=$(git -C "$dir" remote get-url origin 2>/dev/null | \
		sed 's|.*github.com[:/]||;s|\.git$||') || slug=""

	printf '%s' "$slug"
	return 0
}

#######################################
# Post an ORPHAN_REATTACHED audit comment to the GitHub issue so the audit
# trail shows the worker was reattached after a pulse restart.
#
# Best-effort — failures are silently ignored.
#
# Args:
#   $1 - issue_number
#   $2 - repo_slug (owner/repo)
#   $3 - worker_pid
#######################################
_reaper_post_recovery_comment() {
	local issue_number="$1"
	local repo_slug="$2"
	local worker_pid="$3"

	[[ "$issue_number" =~ ^[0-9]+$ ]] || return 0
	[[ -n "$repo_slug" ]] || return 0

	local ts
	ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	local body
	body="<!-- ops:start — workers: skip this comment, it is audit trail not implementation context -->
ORPHAN_REATTACHED reason=pulse_restart worker_pid=${worker_pid} ts=${ts}

Worker PID ${worker_pid} survived a previous pulse-wrapper.sh restart. It has been reattached to the new pulse instance's dispatch ledger and will continue under normal watchdog supervision. No action needed.
<!-- ops:end -->"

	gh api "repos/${repo_slug}/issues/${issue_number}/comments" \
		--method POST --field body="$body" \
		>/dev/null 2>&1 || true
	return 0
}

#######################################
# Kill a stuck orphan worker (running > ORPHAN_REAPER_STUCK_AGE_S with no
# ledger entry) and post an ORPHAN_STUCK_KILLED audit comment.
#
# Uses _kill_tree (graceful) then _force_kill_tree (if still alive) from
# worker-lifecycle-common.sh. Best-effort — failures are logged and ignored.
#
# Args:
#   $1 - worker_pid
#   $2 - issue_number
#   $3 - repo_slug (owner/repo; may be empty)
#   $4 - age_seconds
#######################################
_reaper_kill_stuck_orphan() {
	local worker_pid="$1"
	local issue_number="$2"
	local repo_slug="$3"
	local age_seconds="$4"

	local age_h=$(( age_seconds / 3600 ))
	local age_m=$(( (age_seconds % 3600) / 60 ))

	echo "[orphan-worker-reaper] Killing stuck orphan PID=${worker_pid} issue=#${issue_number} (${repo_slug:-unknown}): running ${age_h}h${age_m}m with no ledger entry" \
		>>"${LOGFILE:-/dev/null}"

	# Graceful kill of process tree, then force if still alive
	if declare -F _kill_tree >/dev/null 2>&1; then
		_kill_tree "$worker_pid"
	else
		kill "$worker_pid" 2>/dev/null || true
	fi

	# Give the process up to 3 seconds to exit gracefully
	local wait_iter=0
	while [[ "$wait_iter" -lt 3 ]] && kill -0 "$worker_pid" 2>/dev/null; do
		sleep 1
		wait_iter=$((wait_iter + 1))
	done

	if kill -0 "$worker_pid" 2>/dev/null; then
		if declare -F _force_kill_tree >/dev/null 2>&1; then
			_force_kill_tree "$worker_pid"
		else
			kill -9 "$worker_pid" 2>/dev/null || true
		fi
		echo "[orphan-worker-reaper] Force-killed stuck orphan PID=${worker_pid}" \
			>>"${LOGFILE:-/dev/null}"
	fi

	[[ "$issue_number" =~ ^[0-9]+$ ]] || return 0
	[[ -n "$repo_slug" ]] || return 0

	local ts
	ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	local body
	body="<!-- ops:start — workers: skip this comment, it is audit trail not implementation context -->
ORPHAN_STUCK_KILLED reason=orphan_stuck worker_pid=${worker_pid} age_seconds=${age_seconds} ts=${ts}

Worker PID ${worker_pid} for issue #${issue_number} was running for ${age_h}h${age_m}m with no dispatch ledger entry (parent pulse had crashed). Worker killed — issue will be re-queued for dispatch on the next available pulse cycle.
<!-- ops:end -->"

	gh api "repos/${repo_slug}/issues/${issue_number}/comments" \
		--method POST --field body="$body" \
		>/dev/null 2>&1 || true
	return 0
}

#######################################
# Classify a single worker as orphan or not, then act:
#   - In ledger with same PID    → not an orphan, skip
#   - In ledger, different PID   → another active worker registered, skip
#   - Not in ledger, age > stuck → kill (ORPHAN_STUCK_KILLED)
#   - Not in ledger, age ≤ stuck → reattach (re-register + ORPHAN_REATTACHED)
#
# Args:
#   $1 - worker_pid
#   $2 - etime (raw ps etime string, used only for logging)
#   $3 - full command line from ps
#   $4 - ledger_helper path (dispatch-ledger-helper.sh)
# Modifies (by reference, caller accumulates):
#   _REAPER_REATTACHED, _REAPER_KILLED (counters, inherited from caller scope)
#######################################
_reaper_classify_and_act() {
	local worker_pid="$1"
	local etime="$2"
	local cmd_line="$3"
	local ledger_helper="$4"

	# Extract issue number — skip if we can't determine it
	local issue_number
	issue_number=$(_reaper_extract_issue "$cmd_line")
	[[ "$issue_number" =~ ^[0-9]+$ ]] || return 0

	# Extract session key (used for re-registration)
	local session_key
	session_key=$(_reaper_extract_session_key "$cmd_line")
	[[ -n "$session_key" ]] || session_key="issue-${issue_number}"

	# Compute worker age from PID
	local age_seconds=0
	if declare -F _get_process_age >/dev/null 2>&1; then
		age_seconds=$(_get_process_age "$worker_pid")
	fi
	[[ "$age_seconds" =~ ^[0-9]+$ ]] || age_seconds=0

	# Skip very young workers — they may still be mid-registration (stagger delay is 8s)
	if [[ "$age_seconds" -lt "${ORPHAN_REAPER_MIN_AGE_S:-60}" ]]; then
		return 0
	fi

	# Check if this worker is in the dispatch ledger with a live in-flight entry
	local ledger_entry ledger_exit
	ledger_entry=$("$ledger_helper" check-issue --issue "$issue_number" 2>/dev/null)
	ledger_exit=$?

	if [[ "$ledger_exit" -eq 0 && -n "$ledger_entry" ]]; then
		# In-flight entry found with live PID
		local ledger_pid
		ledger_pid=$(printf '%s' "$ledger_entry" | jq -r '.pid // 0' 2>/dev/null) || ledger_pid=0
		# Same PID → already registered, not an orphan
		[[ "$ledger_pid" == "$worker_pid" ]] && return 0
		# Different PID but still live → another worker is registered (possible race
		# or legitimate re-dispatch). Don't interfere.
		return 0
	fi

	# No valid in-flight ledger entry → orphan candidate.
	# Derive repo slug from worktree dir in the command line.
	local worktree_dir repo_slug
	worktree_dir=$(_reaper_extract_dir "$cmd_line")
	repo_slug=$(_reaper_repo_slug_from_dir "$worktree_dir")

	if [[ "${ORPHAN_REAPER_STUCK_AGE_S:-7200}" =~ ^[0-9]+$ ]] && \
	   [[ "$age_seconds" -gt "${ORPHAN_REAPER_STUCK_AGE_S:-7200}" ]]; then
		# Stuck orphan — kill
		_reaper_kill_stuck_orphan "$worker_pid" "$issue_number" "$repo_slug" "$age_seconds"
		_REAPER_KILLED=$((_REAPER_KILLED + 1))
		return 0
	fi

	# Reattach: register the orphan in the ledger with its current PID.
	# cmd_register is idempotent — removes any stale failed entry then adds new.
	"$ledger_helper" register \
		--session-key "$session_key" \
		--issue "$issue_number" \
		--repo "$repo_slug" \
		--pid "$worker_pid" \
		2>/dev/null || true

	echo "[orphan-worker-reaper] Reattached orphan worker PID=${worker_pid} to issue #${issue_number} (${repo_slug:-unknown})" \
		>>"${LOGFILE:-/dev/null}"

	# Post recovery comment so the issue audit trail records the restart event
	if [[ -n "$repo_slug" ]]; then
		_reaper_post_recovery_comment "$issue_number" "$repo_slug" "$worker_pid"
	fi

	_REAPER_REATTACHED=$((_REAPER_REATTACHED + 1))
	return 0
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

#######################################
# Scan active worker processes for orphans (workers with no dispatch ledger
# entry) and either reattach them to the new pulse instance or kill stuck ones.
#
# Called once per cycle at the start of _pulse_run_deterministic_pipeline().
# Safe to call when dependencies are unavailable — returns 0 on any infra
# failure so the pulse cycle is never blocked.
#
# Env vars:
#   ORPHAN_REAPER_ENABLED    — set to 0 to disable (default: 1)
#   ORPHAN_REAPER_MIN_AGE_S  — minimum worker age to consider (default: 60)
#   ORPHAN_REAPER_STUCK_AGE_S — age threshold for stuck-kill (default: 7200)
#   LOGFILE                  — pulse log path (from pulse-wrapper-config.sh)
#   SCRIPT_DIR               — directory containing dispatch-ledger-helper.sh
#
# Returns: 0 always (best-effort — never blocks the pulse cycle)
#######################################
reap_orphan_workers() {
	[[ "${ORPHAN_REAPER_ENABLED:-1}" == "1" ]] || return 0

	# Resolve SCRIPT_DIR — inherited from pulse-wrapper.sh or computed locally
	local _reaper_sdir="${SCRIPT_DIR:-}"
	if [[ -z "$_reaper_sdir" ]]; then
		_reaper_sdir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 0
	fi
	local ledger_helper="${_reaper_sdir}/dispatch-ledger-helper.sh"

	# Guard: ledger helper must be available and executable
	[[ -x "$ledger_helper" ]] || return 0

	# Guard: list_active_worker_processes must be available from worker-lifecycle-common.sh
	declare -F list_active_worker_processes >/dev/null 2>&1 || return 0

	# Accumulate counters (visible to _reaper_classify_and_act via shared scope)
	local _REAPER_REATTACHED=0
	local _REAPER_KILLED=0

	local worker_lines
	worker_lines=$(list_active_worker_processes 2>/dev/null) || return 0
	[[ -n "$worker_lines" ]] || return 0

	while IFS= read -r line; do
		[[ -z "$line" ]] && continue

		# Output format from list_active_worker_processes (via list_active_workers.awk):
		#   "pid etime command..."
		local worker_pid worker_etime
		read -r worker_pid worker_etime <<<"$line"
		[[ "$worker_pid" =~ ^[0-9]+$ ]] || continue

		# Skip our own process
		[[ "$worker_pid" == "$$" ]] && continue

		# Reconstruct full command (everything after "pid etime")
		local worker_cmd
		worker_cmd="${line#"${worker_pid}" "${worker_etime}" }"

		_reaper_classify_and_act \
			"$worker_pid" "$worker_etime" "$worker_cmd" "$ledger_helper"

	done <<<"$worker_lines"

	if [[ "$_REAPER_REATTACHED" -gt 0 || "$_REAPER_KILLED" -gt 0 ]]; then
		echo "[orphan-worker-reaper] Cycle: reattached=${_REAPER_REATTACHED} killed=${_REAPER_KILLED}" \
			>>"${LOGFILE:-/dev/null}"
	fi

	return 0
}
