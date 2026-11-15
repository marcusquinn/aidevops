#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Pulse wrapper defaults: triage, large-file gate, merge, LLM supervisor and routine settings.
# Sourced by pulse-wrapper.sh after the admission helpers (GH#38106).
# Dependencies: SCRIPT_DIR, HOME, config_get (config-helper.sh).

[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail
[[ -n "${_PULSE_WRAPPER_DEFAULTS_LOADED:-}" ]] && return 0
_PULSE_WRAPPER_DEFAULTS_LOADED=1

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

#######################################
# Daily complexity scan helpers (GH#5628, GH#15285)
#######################################

#######################################
# Simplification state tracking — git-committed registry of simplified files.
#
# State file: .agents/configs/simplification-state.json (in repo, on main)
# Format: { "files": { "path": { "hash": "<git blob sha>", "at": "ISO", "pr": N } } }
#
# - "hash" is the git blob SHA of the file at simplification time
# - When scan sees a file in state with matching hash → skip (already done)
# - When hash differs → file changed since simplification → create recheck issue
# - State is committed to main and pushed, so all users share it
#######################################

#######################################
# Complexity scan (GH#5628, GH#15285)
#
# Deterministic scan using shell-based heuristics via complexity-scan-helper.sh:
# - Batch hash comparison against simplification-state.json (skip unchanged files)
# - Shell heuristics: line count, function count, nesting depth
# - No per-file LLM analysis — LLM reserved for daily deep sweep only
#
# Scans both shell scripts (.sh) and agent docs (.md) for complexity:
# - .sh files: functions exceeding COMPLEXITY_FUNC_LINE_THRESHOLD lines
# - .md files: agent docs at/above COMPLEXITY_MD_MIN_LINES (default 500);
#   classification determines compress-vs-split action.
#
# Protected files (build.txt, AGENTS.md, pulse.md, pulse-sweep.md) are excluded.
# Results processed longest-first. .md issues get tier:standard by default.
#
# Daily LLM sweep (GH#15285): if simplification debt hasn't decreased in 6h,
# creates a tier:thinking issue for LLM-powered deep review of stalled debt.
#
# Runs at most once per COMPLEXITY_SCAN_INTERVAL (default 15 min).
# Creates up to 5 issues per run; open cap (500) prevents backlog flooding.
#
# Returns: 0 always (best-effort, never breaks the pulse)
#######################################

# count_active_workers: now provided by worker-lifecycle-common.sh (sourced above).
# Removed from pulse-wrapper.sh to eliminate divergence with stats-functions.sh.

#######################################
# Triage content-hash dedup (GH#17746).
#
# Without dedup, NMR issues are re-triaged every pulse cycle:
# lock → agent → no output → unlock → repeat. This wastes tokens,
# API calls, and pollutes the issue timeline with lock/unlock events.
#
# Strategy: hash the issue body + human comments (excluding bot and
# review comments). Cache the hash. Skip triage when content is
# unchanged. Re-triage when the author edits the body or adds a
# new comment.
#######################################
TRIAGE_CACHE_DIR="${TRIAGE_CACHE_DIR:-${HOME}/.aidevops/.agent-workspace/tmp/triage-cache}"

#######################################
# GH#17827, t2014: Triage failure retry cap (default 1 — single attempt).
#
# When triage fails (no review posted), the GH#17873 fix intentionally
# skips caching the content hash so the next cycle retries. But failing
# triages are overwhelmingly deterministic (format-validation rejections,
# not transient model quota) — three retries per content version burn
# three full opus agent invocations (~100K chars each) and three
# lock/unlock pairs on the issue timeline, all to reach the same outcome.
#
# Solution: cap retries at 1. The FIRST failure increments the counter
# to 1, sees 1 >= TRIAGE_MAX_RETRIES, caches the hash, and marks the
# issue with triage-failed. Subsequent cycles skip via the content-hash
# cache — zero lock/unlock, zero agent invocations. A new human comment
# changes the hash and resets the counter, giving another attempt.
#
# Transient failures (network, gh API, model rate-limit) are caught
# earlier in the dispatch loop (before lock_issue_for_worker) or
# handled by the model rotation pool, so the retry budget here adds no
# value for transients — only cost for deterministic failures.
#
# Maintainers can force a re-triage by removing the triage-failed label
# and the corresponding .failures/.hash files in TRIAGE_CACHE_DIR.
#######################################
TRIAGE_MAX_RETRIES="${TRIAGE_MAX_RETRIES:-1}"

#######################################
# Atomic dispatch: dedup guard + assign + launch in a single call (GH#12436)
#
# Root cause of GH#12141 and GH#12155: the pulse.md instructed the LLM to
# run check_dispatch_dedup, then gh issue edit, then headless-runtime-helper.sh
# as three separate steps. The LLM skipped check_dispatch_dedup entirely in
# both incidents — zero DISPATCH_CLAIM comments were posted. This function
# makes the dedup guard non-skippable by wrapping all three steps into a
# single deterministic call. The LLM calls one function; the function
# enforces all 7 dedup layers before assigning and launching.
#
# Arguments:
#   $1 - issue_number
#   $2 - repo_slug (owner/repo)
#   $3 - dispatch_title (e.g., "Issue #42: Fix auth")
#   $4 - issue_title (e.g., "t042: Fix auth" — for merged-PR fallback)
#   $5 - self_login (runner's GitHub login)
#   $6 - repo_path (local path to the repo for the worker)
#   $7 - prompt (full prompt string for the worker, e.g., "/full-loop ...")
#   $8 - session_key (optional; defaults to "issue-${issue_number}")
#
# Exit codes:
#   0 - dispatched successfully
#   1 - dedup guard blocked dispatch (duplicate detected)
#   2 - dispatch failed after passing dedup (assign or launch error)
#######################################

#######################################
# Issue consolidation: detect multi-comment issues where substantive
# comments (not dispatch/approval machinery) have materially changed
# the issue's scope since the body was written.
#
# Threshold: ISSUE_CONSOLIDATION_COMMENT_THRESHOLD (default 2) substantive
# comments with >500 chars each (excludes dispatch claims, approval sigs,
# bot comments, and recovery comments).
#
# When triggered, adds a "needs-consolidation" label and posts a comment
# explaining the action. The issue is skipped for dispatch until a
# consolidation worker merges the comment thread into a clean issue.
#
# Arguments: $1 issue_number, $2 repo_slug
# Returns: 0 if consolidation is needed, 1 if not
#
# Defaults are owned by pulse-triage.sh (module-level := block) which is
# sourced above. Declarations removed from here to eliminate duplicate-default
# drift (t2143). Override via env before sourcing pulse-triage.sh if needed.
#######################################

#######################################
# Large-file simplification gate: check if an issue body references
# files that exceed a line count threshold, indicating the worker will
# spend most of its context budget just reading the target file.
#
# When a large file is detected, the function:
#   1. Checks if a simplification task already exists for that file
#   2. If not, logs the finding for the simplification routine to pick up
#   3. Adds a label so the issue is held until simplification runs
#
# Arguments: $1 issue_number, $2 repo_slug, $3 issue_body, $4 repo_path
# Returns: 0 if gate triggered (hold dispatch), 1 if clear
#######################################
LARGE_FILE_LINE_THRESHOLD="${LARGE_FILE_LINE_THRESHOLD:-2000}"

# t2024: Scoped-range exemption for the large-file gate.
#
# The gate's purpose is to prevent a worker from paying the complexity tax
# of navigating a huge file when it only needs to understand a small section.
# If the issue body cites an explicit line range (e.g., "EDIT: file.sh:221-253")
# and the range is at most SCOPED_RANGE_THRESHOLD lines, the worker can
# navigate the cited range directly without reading the whole file — so we
# pass the gate regardless of the enclosing file's total line count.
#
# Single-line citations (e.g., "file.sh:1477") are treated as context references
# for the human reader, not implementation targets, and are excluded from
# gate evaluation entirely. A worker never "edits line 1477" — they edit a
# function or a range; a bare line number is documentation, not a target.
#
# File references without any line qualifier (e.g., "file.sh") fall through
# to the existing file-size check — this preserves the original safety for
# whole-file rewrites where the worker really does need to understand everything.
SCOPED_RANGE_THRESHOLD="${SCOPED_RANGE_THRESHOLD:-300}"

#######################################
# Per-issue retry state (t1888, GH#2076, GH#17384)
#
# Cause-aware retry backoff. See config block at line ~205 for the full
# decision tree. Key invariant: rate-limit failures with available accounts
# do NOT increment the counter or delay retry — they rotate immediately.
# Only exhaustion of all accounts or non-rate-limit failures trigger backoff.
#
# State file: FAST_FAIL_STATE_FILE (JSON, ~200 bytes per entry)
# Format: { "slug/number": { "count": N, "ts": epoch, "reason": "...",
#            "retry_after": epoch, "backoff_secs": N } }
#
# Integration points:
#   - pulse-wrapper.sh: fast_fail_record() on launch failure (recover_failed_launch_state)
#   - worker-watchdog.sh: _watchdog_record_failure_and_escalate() on worker kill
#   - pulse-wrapper.sh: fast_fail_reset() on PR merge / issue close
#   - pulse-wrapper.sh: fast_fail_is_skipped() in deterministic dispatch loop
#
# All functions are best-effort — failures are logged but never fatal.
#######################################

# dispatch_count_exceeded removed (t1927). An arbitrary hard cap on dispatch
# attempts gives up instead of solving. The correct approach is:
#   1. fast_fail with exponential backoff (already implemented) — gives the
#      system breathing room between attempts
#   2. escalate_issue_tier (already implemented) — moves to higher-capability
#      models after consecutive failures
#   3. stale recovery records fast-fail (already implemented) — silent timeouts
#      count as failures and feed into backoff + escalation
#   4. blocked-by enforcement (already implemented) — skips genuinely blocked work
#
# Together, these ensure the system keeps trying with progressively more
# capable models and longer backoff intervals, rather than giving up at an
# arbitrary number. The measure of success is issues getting solved, not
# issues getting labeled "stuck".

#######################################
# Apply dispatch_max after a pulse pass.
#######################################
# Deterministic merge pass: approve and merge all ready PRs.
#
# Runs every pulse cycle as a wrapper-level stage (not LLM-dependent).
# This prevents PR backlogs from accumulating when the LLM fails to
# execute merge steps or the prefetch was broken.
#
# A PR is merge-ready when ALL of:
#   1. mergeable == MERGEABLE (not conflicting)
#   2. Author is a collaborator (admin/maintain/write permission)
#   3. Not modifying .github/workflows/ without workflow token scope
#   4. No linked issue with needs-maintainer-review label
#   5. Not from an external contributor
#
# REVIEW_REQUIRED is not a blocker — the pulse user auto-approves
# collaborator PRs via approve_collaborator_pr().
#
# Conflicting PRs are closed with a comment (they will be superseded
# by workers re-dispatching the issue).
#
# Returns: 0 always (non-fatal — merge failures don't block the pulse)
#######################################
PULSE_MERGE_BATCH_LIMIT="${PULSE_MERGE_BATCH_LIMIT:-50}"
PULSE_MERGE_CLOSE_CONFLICTING="${PULSE_MERGE_CLOSE_CONFLICTING:-true}"

#######################################
# Decide whether to invoke the LLM supervisor this cycle.
#
# Returns 0 (true = run LLM) when:
#   - Last LLM run was >24h ago (daily sweep)
#   - Backlog is stalled: issue+PR count unchanged for 30+ min
#   - No backlog snapshot exists yet (first run)
#
# Returns 1 (false = skip LLM) when:
#   - Backlog is progressing (counts are decreasing)
#   - Daily sweep not yet due
#
# Side effect: writes the trigger mode to ${PULSE_DIR}/llm_trigger_mode
#   Values: "daily_sweep" | "stall" | "first_run"
#   Callers read this file to select the correct agent prompt
#   (pulse-sweep.md for daily_sweep, pulse.md for stall/first_run).
#
# State files:
#   ${PULSE_DIR}/last_llm_run_epoch     — epoch of last LLM invocation
#   ${PULSE_DIR}/backlog_snapshot.txt    — "epoch issues_count prs_count"
#   ${PULSE_DIR}/llm_trigger_mode        — last trigger reason (daily_sweep|stall|first_run)
#######################################
PULSE_LLM_STALL_THRESHOLD="${PULSE_LLM_STALL_THRESHOLD:-$(config_get "orchestration.llm_stall_threshold" "3600")}" # 1h (was 30 min; dispatch_max handles routine dispatch)
PULSE_LLM_DAILY_INTERVAL="${PULSE_LLM_DAILY_INTERVAL:-86400}"                                                      # 24h

#######################################
# Routine evaluation (t1925)
#
# Evaluates repeat: fields in TODO.md routines sections across pulse-enabled
# repos. Dispatches due routines:
#   - run: → execute script directly (zero LLM tokens)
#   - agent: → dispatch via headless-runtime-helper.sh
#
# State file: ~/.aidevops/.agent-workspace/routine-state.json
# Schedule parser: routine-schedule-helper.sh
#######################################
ROUTINE_STATE_FILE="${HOME}/.aidevops/.agent-workspace/routine-state.json"
ROUTINE_SCHEDULE_HELPER="${SCRIPT_DIR}/routine-schedule-helper.sh"
ROUTINE_LOG_HELPER="${SCRIPT_DIR}/routine-log-helper.sh"
