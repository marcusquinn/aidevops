#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Pulse wrapper worker defaults: stalled-worker, stale-session and enrichment settings.
# Sourced by pulse-wrapper.sh after the main() phase helpers (GH#38106).
# Dependencies: none beyond the caller environment.

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail
[[ -n "${_PULSE_WRAPPER_WORKER_DEFAULTS_LOADED:-}" ]] && return 0
_PULSE_WRAPPER_WORKER_DEFAULTS_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

#######################################
# Clean verified stale OpenCode sessions
#
# Criteria (ALL must be true):
#   - Explicit disposable session mode (`opencode run`)
#   - Not owned by a managed service cgroup
#   - Older than ORPHAN_MAX_AGE seconds
#   - Session DB activity older than ORPHAN_INACTIVITY_AGE seconds
#   - Process tree is idle, with all evidence revalidated before SIGTERM
#
# Persistent modes, active sessions, and ambiguous evidence fail closed.
# The classifier covers both no-TTY and TTY-attached disposable sessions but
# never kills an unrelated parent terminal shell.
#######################################

#######################################
# Kill workers stalled on rate-limited providers.
#
# When a provider hits its rate limit, already-running workers don't exit —
# they hang indefinitely waiting for the API to respond. The retry/rotation
# logic in headless-runtime-helper.sh only runs AFTER the process exits,
# creating a deadlock: worker waits for API → API is rate-limited → worker
# never exits → rotation never fires → slot wasted permanently.
#
# Observed in production: 20 of 24 worker slots consumed by stalled openai
# workers with 306 bytes of output (just the sandbox startup line, zero LLM
# activity) for 20-30 minutes. 0% CPU, 0 commits, 0 PRs.
#
# Detection: a worker running >STALLED_WORKER_MIN_AGE seconds with a log
# file ≤STALLED_WORKER_MAX_LOG_BYTES is stalled. The log file only contains
# the sandbox startup line when the LLM never responded.
#
# Action: kill the stalled worker, record provider backoff so the next
# dispatch rotates to a working provider, and log the kill for audit.
#######################################
STALLED_WORKER_MIN_AGE="${STALLED_WORKER_MIN_AGE:-300}"             # 5 minutes
STALLED_WORKER_MAX_LOG_BYTES="${STALLED_WORKER_MAX_LOG_BYTES:-500}" # just the startup line

#######################################
# Legacy compatibility: cleanup_stale_opencode remains callable, but its unsafe
# age/CPU-only TTY cleanup is consolidated into cleanup_orphans.
#######################################
STALE_OPENCODE_MAX_AGE="${STALE_OPENCODE_MAX_AGE:-28800}" # 8 hours — was 4h, increased to avoid killing long-running complex tasks

#######################################
# Enrich failed issues with thinking-tier analysis before re-dispatch.
#
# When a worker fails (premature_exit, idle kill), the issue body often
# lacks the implementation context needed for success. This function
# spawns an inline thinking-tier worker to analyze the codebase and append
# a "## Worker Guidance" section with concrete file paths, patterns,
# and verification commands.
#
# Triggered by: fast_fail_record sets enrichment_needed=true on the
# first non-rate-limit failure. Runs at most once per issue.
#
# Arguments:
#   $1 - available worker slots
# Outputs: updated available count to stdout
# Exit code: always 0
#######################################
ENRICHMENT_MAX_PER_CYCLE="${ENRICHMENT_MAX_PER_CYCLE:-2}"

#######################################
# Dispatch FOSS contribution workers when idle capacity exists (t1702)
#
# Reads the pre-fetched FOSS scan from STATE_FILE and dispatches workers
# for eligible repos. Respects the FOSS_MAX_DISPATCH_PER_CYCLE cap and
# available worker slots.
#
# Arguments:
#   $1 - available worker slots (AVAILABLE)
#   $2 - repos JSON path (default: REPOS_JSON)
#
# Outputs: updated available count to stdout (one integer)
# Exit code: always 0
#######################################

#######################################
# Sync GitHub issue refs to TODO.md and close completed issues for a repo
#
# Arguments:
#   $1 - repo slug (owner/repo)
#   $2 - repo path (canonical path on disk)
#
# Exit code: always 0
#######################################
# sync_todo_refs_for_repo and _pulse_is_sourced provided by
# pulse-wrapper-cycle.sh (GH#21311 / t2936-child).
