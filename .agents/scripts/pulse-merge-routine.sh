#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-merge-routine.sh — Standalone fast-cadence merge routine (t2862, GH#20919)
#
# Decouples `merge_ready_prs_all_repos()` from the monolithic pulse cycle so
# green PRs are merged within ~3 min of CI completion regardless of how long
# the preflight stack takes (typically 5-10 min for a full pulse cycle).
#
# Problem: the pulse cycle's preflight stack
# (`preflight_cleanup_and_ledger` + `preflight_capacity_and_labels` +
# `preflight_early_dispatch` + `complexity_scan` etc.) often takes 5+ min
# before `deterministic_merge_pass` starts. In a 24h sample, the merge pass
# ran only ~7 times despite ~40+ pulse cycles. Green `origin:interactive` +
# OWNER PRs sat unmerged for 10+ minutes; the workaround was `gh pr merge
# --admin --squash`, which works but should not be the primary path.
#
# Solution: run merge_ready_prs_all_repos() as a fast independent routine on
# a 120s launchd/cron schedule. The in-cycle merge call in pulse-wrapper.sh
# is kept as defense-in-depth but short-circuits when this routine ran within
# the last 60s (file-timestamp marker at PULSE_MERGE_ROUTINE_LAST_RUN).
#
# Architecture: modelled on complexity-scan-runner.sh (t2903) — independent
# file-based lock (mkdir, PID stale-reclaim), runner-level log, minimal
# source chain, --dry-run / --repo / --pr spot-check flags.
#
# Usage:
#   pulse-merge-routine.sh [run]           Run the merge pass (default; called by launchd)
#   pulse-merge-routine.sh --dry-run       Dry-run: print what would be merged, no side effects
#   pulse-merge-routine.sh --repo SLUG     Limit to a single repo
#   pulse-merge-routine.sh --pr N          Spot-check one PR (requires --repo)
#   pulse-merge-routine.sh help            Show usage
#
# Lock:       ~/.aidevops/.agent-workspace/locks/pulse-merge-routine.lock
# Runner log: ~/.aidevops/logs/pulse-merge-routine.log
# Last-run:   ~/.aidevops/logs/pulse-merge-routine-last-run
#             (also written as PULSE_MERGE_ROUTINE_LAST_RUN; read by pulse-wrapper.sh
#             short-circuit)
#
# Part of aidevops framework: https://aidevops.sh

set -euo pipefail

# PATH normalisation for launchd/cron environments where PATH is minimal.
export PATH="/opt/homebrew/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin:/bin:/usr/bin:${PATH}"

# SCRIPT_DIR resolution — uses BASH_SOURCE[0]:-$0 for zsh portability (GH#3931).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# =============================================================================
# Source pulse libraries
# =============================================================================
# Order matters (mirrors complexity-scan-runner.sh):
#   1. shared-constants.sh  — bash 4+ re-exec guard fires here at depth 1; also
#                             auto-sources shared-gh-wrappers.sh.
#   2. config-helper.sh     — provides config_get used by pulse-wrapper-config.sh.
#   3. worker-lifecycle-common.sh — provides _validate_int used by pulse-wrapper-config.sh.
#   4. credentials.sh       — picks up gh tokens / API keys before merge calls gh.
#   5. pulse-wrapper-config.sh — defines LOGFILE, REPOS_JSON, STOP_FLAG, etc.
#   6. pulse-repo-meta.sh   — get_repo_role_by_slug, get_repo_path_by_slug.
#   7. pulse-dispatch-core.sh — provides unlock_issue_after_worker (called from
#                             pulse-merge.sh:338,385 in _handle_post_merge_actions
#                             and _handle_post_close_actions). Without this,
#                             stderr emits 'unlock_issue_after_worker: command not
#                             found' on every merged/closed PR (t3036).
#   8. pulse-fast-fail.sh   — provides fast_fail_reset (called from pulse-merge.sh:383
#                             in _handle_post_close_actions). Without this, stderr
#                             emits 'fast_fail_reset: command not found' on every
#                             closed PR (t3036).
#   9. pulse-merge.sh       — merge_ready_prs_all_repos + gate helpers; also
#                             transitively sources shared-claim-lifecycle.sh and
#                             shared-phase-filing.sh.
#  10. pulse-merge-conflict.sh — conflict handling, interactive PR handover.
#  11. pulse-merge-feedback.sh — CI/conflict/review feedback routing to linked issues.
#
# pulse-merge.sh normally requires PULSE_MERGE_BATCH_LIMIT and PULSE_START_EPOCH
# to be set by the pulse-wrapper.sh bootstrap (lines 180, 727). They are
# initialised below in the env-var defaults section before any function is
# called (see also the ${VAR:-default} guards added to merge_ready_prs_all_repos
# itself in t2862 — belt-and-suspenders).

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/config-helper.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/worker-lifecycle-common.sh"

if [[ -f "${HOME}/.config/aidevops/credentials.sh" ]]; then
	# shellcheck source=/dev/null
	. "${HOME}/.config/aidevops/credentials.sh" 2>/dev/null || true
fi

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-wrapper-config.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-repo-meta.sh"
# t3036 (GH#21616): pulse-dispatch-core defines unlock_issue_after_worker;
# pulse-fast-fail defines fast_fail_reset. Both are called from
# _handle_post_merge_actions / _handle_post_close_actions in pulse-merge.sh.
# Without these, every successful merge/close emits 'command not found'
# stderr noise. Source defensively before pulse-merge.sh.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-dispatch-core.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-fast-fail.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-merge.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-merge-conflict.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/pulse-merge-feedback.sh"

# =============================================================================
# Env-var defaults (belt-and-suspenders — also guarded inside the function)
# =============================================================================

# PULSE_MERGE_BATCH_LIMIT is normally set by pulse-wrapper.sh:727. Set a
# safe default here so standalone invocation doesn't hit an unbound variable.
PULSE_MERGE_BATCH_LIMIT="${PULSE_MERGE_BATCH_LIMIT:-50}"

# PULSE_START_EPOCH is normally set by pulse-wrapper.sh:180 (the canonical
# bootstrap path). It's referenced by pulse-merge.sh:326 inside
# _handle_post_merge_actions and by pulse-simplification-*.sh. Under
# `set -euo pipefail` (line 42 of this file), an unset reference is a hard
# fail — every launchd invocation would crash before doing anything useful
# (t3036, GH#21616). Initialise to current epoch so elapsed-time math works
# even when no pulse cycle preceded this invocation. Export so subprocesses
# (gh-signature-helper.sh, etc.) inherit the value consistently.
PULSE_START_EPOCH="${PULSE_START_EPOCH:-$(date +%s)}"
export PULSE_START_EPOCH

# STOP_FLAG / REPOS_JSON: normally set by pulse-wrapper-config.sh; the
# ${VAR:-default} guards below are defence-in-depth for edge-case sourcing
# order issues (e.g. unit test harnesses that source a subset of the chain).
STOP_FLAG="${STOP_FLAG:-${HOME}/.aidevops/logs/pulse-session.stop}"
REPOS_JSON="${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"

# =============================================================================
# Runner-level state files
# =============================================================================

RUNNER_LOG_FILE="${HOME}/.aidevops/logs/pulse-merge-routine.log"
LOCK_DIR="${HOME}/.aidevops/.agent-workspace/locks/pulse-merge-routine.lock"
PULSE_MERGE_ROUTINE_LAST_RUN="${HOME}/.aidevops/logs/pulse-merge-routine-last-run"

mkdir -p "$(dirname "$RUNNER_LOG_FILE")" "$(dirname "$LOCK_DIR")"

# =============================================================================
# Logging
# =============================================================================

_pmr_log() {
	local level="$1"
	shift
	local timestamp
	timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	printf '[%s] [%s] %s\n' "$timestamp" "$level" "$*" >>"$RUNNER_LOG_FILE"
	return 0
}

# =============================================================================
# File-based lock (mkdir-based for bash 3.2 + macOS portability)
# =============================================================================
# mkdir is atomic on POSIX filesystems and works without flock (Linux-only) or
# any FD-inheritance gotchas. PID-based stale detection lets the next runner
# reclaim the lock if the previous instance crashed.

_pmr_release_lock() {
	rm -rf "$LOCK_DIR" 2>/dev/null || true
	return 0
}

_pmr_acquire_lock() {
	if mkdir "$LOCK_DIR" 2>/dev/null; then
		printf '%s\n' "$$" >"${LOCK_DIR}/pid"
		trap '_pmr_release_lock' EXIT INT TERM
		return 0
	fi

	# Lock dir exists — check if owner is alive.
	local owner_pid=""
	if [[ -f "${LOCK_DIR}/pid" ]]; then
		owner_pid=$(cat "${LOCK_DIR}/pid" 2>/dev/null || true)
	fi
	if [[ -n "$owner_pid" ]] && kill -0 "$owner_pid" 2>/dev/null; then
		_pmr_log INFO "Skipping: previous instance still running (pid=${owner_pid})"
		return 1
	fi

	# Stale lock — reclaim. mkdir again after rm to confirm we won the race.
	rm -rf "$LOCK_DIR" 2>/dev/null || true
	if mkdir "$LOCK_DIR" 2>/dev/null; then
		printf '%s\n' "$$" >"${LOCK_DIR}/pid"
		trap '_pmr_release_lock' EXIT INT TERM
		_pmr_log WARN "Reclaimed stale lock (was pid=${owner_pid:-unknown})"
		return 0
	fi
	_pmr_log WARN "Could not acquire lock after stale-reclaim attempt"
	return 1
}

# =============================================================================
# Commands
# =============================================================================

cmd_run() {
	_pmr_log INFO "Starting merge routine (pid=$$)"
	if ! _pmr_acquire_lock; then
		exit 0
	fi

	local merge_exit=0
	merge_ready_prs_all_repos || merge_exit=$?

	# Write epoch to last-run marker so pulse-wrapper.sh short-circuit can
	# compare elapsed time via cat (consistent with DIRTY_PR_SWEEP_LAST_RUN pattern).
	date +%s >"$PULSE_MERGE_ROUTINE_LAST_RUN" 2>/dev/null || true
	_pmr_log INFO "Merge routine completed (exit=${merge_exit})"
	return "$merge_exit"
}

cmd_help() {
	cat <<EOF
pulse-merge-routine.sh — Standalone fast-cadence merge routine (t2862, GH#20919)

Usage:
  pulse-merge-routine.sh [run]         Run the merge pass (default; called by launchd)
  pulse-merge-routine.sh --dry-run     Dry-run: print what would be merged, no side effects
  pulse-merge-routine.sh --repo SLUG   Limit to a single repo
  pulse-merge-routine.sh --pr N        Spot-check one PR (requires --repo)
  pulse-merge-routine.sh help          Show this help

Scheduled via launchd: sh.aidevops.pulse-merge-routine (every 120s, RunAtLoad=true).
Install via setup.sh / setup_pulse_merge_routine in setup-modules/schedulers.sh.

Paths:
  Lock dir:    ${LOCK_DIR}
  Runner log:  ${RUNNER_LOG_FILE}
  Pulse log:   ${LOGFILE:-~/.aidevops/logs/pulse.log}
  Last-run:    ${PULSE_MERGE_ROUTINE_LAST_RUN}

The underlying pass (merge_ready_prs_all_repos in pulse-merge.sh) processes all
pulse-enabled repos from REPOS_JSON (${REPOS_JSON}). The in-cycle merge call
in pulse-wrapper.sh short-circuits when this routine ran within the last 60s.

Env overrides:
  PULSE_MERGE_BATCH_LIMIT=50   Max PRs fetched per repo per run.
  DRY_RUN=1                    Same as --dry-run.
EOF
	return 0
}

# Dry-run: set DRY_RUN=1 so merge_ready_prs_all_repos logs "would merge" but
# skips actual gh pr merge calls. The underlying function checks DRY_RUN via
# the shared wrapper helpers.
cmd_dry_run() {
	export DRY_RUN=1
	_pmr_log INFO "DRY-RUN mode: merge routine (pid=$$)"
	if ! _pmr_acquire_lock; then
		exit 0
	fi

	local merge_exit=0
	merge_ready_prs_all_repos || merge_exit=$?
	_pmr_log INFO "DRY-RUN merge routine completed (exit=${merge_exit})"
	return "$merge_exit"
}

# =============================================================================
# Entry point
# =============================================================================

_pmr_main() {
	local _subcommand="${1:-run}"
	local _repo_filter=""
	local _pr_filter=""

	while [[ $# -gt 0 ]]; do
		local _arg="$1"
		local _next="${2:-}"
		case "$_arg" in
		run | --run | "")
			_subcommand="run"
			shift
			;;
		--dry-run | dry-run)
			_subcommand="dry-run"
			shift
			;;
		--repo)
			_repo_filter="$_next"
			shift 2
			;;
		--repo=*)
			_repo_filter="${_arg#--repo=}"
			shift
			;;
		--pr)
			_pr_filter="$_next"
			shift 2
			;;
		--pr=*)
			_pr_filter="${_arg#--pr=}"
			shift
			;;
		help | -h | --help)
			_subcommand="help"
			shift
			;;
		*)
			printf 'Unknown option: %s\n' "$_arg" >&2
			printf "Run '%s help' for usage.\n" "$0" >&2
			return 2
			;;
		esac
	done

	# Single-repo or single-PR spot mode: override REPOS_JSON with a synthetic
	# single-entry repo list so merge_ready_prs_all_repos only processes that repo.
	if [[ -n "$_repo_filter" ]]; then
		local _SPOT_REPOS_JSON
		_SPOT_REPOS_JSON="$(mktemp)"
		# shellcheck disable=SC2064
		trap "rm -f '$_SPOT_REPOS_JSON' 2>/dev/null || true" EXIT INT TERM
		printf '{"initialized_repos":[{"slug":"%s","pulse":true,"local_only":false,"path":""}]}\n' \
			"$_repo_filter" >"$_SPOT_REPOS_JSON"
		REPOS_JSON="$_SPOT_REPOS_JSON"
		if [[ -n "$_pr_filter" ]]; then
			_pmr_log INFO "Spot-check: --repo=${_repo_filter} --pr=${_pr_filter}"
			# For single-PR mode, set PULSE_MERGE_BATCH_LIMIT to 1 and let the
			# function discover and process only that PR. Note: the current
			# merge_ready_prs_all_repos API processes all open ready PRs for the
			# repo; single-PR filtering is a best-effort convenience.
			PULSE_MERGE_BATCH_LIMIT=1
		else
			_pmr_log INFO "Spot-check: --repo=${_repo_filter}"
		fi
	fi

	case "$_subcommand" in
	run)
		cmd_run
		;;
	dry-run)
		cmd_dry_run
		;;
	help)
		cmd_help
		;;
	*)
		printf 'Unknown command: %s\n' "$_subcommand" >&2
		printf "Run '%s help' for usage.\n" "$0" >&2
		return 2
		;;
	esac
	return 0
}

_pmr_main "$@"
exit $?
