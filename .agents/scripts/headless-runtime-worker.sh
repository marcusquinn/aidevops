#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Headless Runtime Worker -- Worker lifecycle, invocation support & preparation
# =============================================================================
# Worker-specific helpers: auth rotation, rate-limit monitoring, Claude CLI
# invocation, output preservation, output classification, orphan handling,
# run preparation/retry/finish, detach, and stall-cap checks.
#
# Usage: source "${SCRIPT_DIR}/headless-runtime-worker.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, print_warning, etc.)
#   - headless-runtime-lib.sh (extract_provider, append_runtime_metric, etc.)
#   - shared-claim-lifecycle.sh (_attempt_orphan_recovery_pr, _release_dispatch_claim, etc.)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_HEADLESS_RUNTIME_WORKER_LIB_LOADED:-}" ]] && return 0
_HEADLESS_RUNTIME_WORKER_LIB_LOADED=1

# Module-local string constants (avoid ratchet repeated-literal violations)
_HRW_STATUS_FAIL="fail"
_HRW_STATUS_UNKNOWN="unknown"

# Defensive SCRIPT_DIR fallback (test harnesses may not set it)
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# Runtime invocation support — auth rotation & rate-limit monitoring
# =============================================================================

# _maybe_rotate_isolated_auth: pre-dispatch OAuth rotation check for headless workers (t2249).
#
# When the account copied into the isolated auth.json is currently in
# cooldown per the SHARED pool metadata (recorded by a prior worker's
# mark-failure), rotate the isolated file to a healthy account BEFORE
# opencode spawns. This prevents wasted dispatches on known-dead accounts.
#
# Safe because OPENCODE_AUTH_FILE in oauth-pool-helper.sh is now
# XDG_DATA_HOME-aware (t2249): rotate writes to the ISOLATED file,
# not the shared interactive auth.json.
#
# Args: $1 = absolute path to the isolated auth.json
#       $2 = provider (e.g., "anthropic")
# Returns: 0 always — best-effort; rotation failure must not block dispatch.
_maybe_rotate_isolated_auth() {
	local isolated_auth="$1"
	local provider="$2"
	local pool_file="${AIDEVOPS_OAUTH_POOL_FILE:-${HOME}/.aidevops/oauth-pool.json}"
	local oauth_helper="${OAUTH_POOL_HELPER:-${HOME}/.aidevops/agents/scripts/oauth-pool-helper.sh}"

	# Skip silently when prerequisites are missing (jq, pool, isolated auth, helper).
	command -v jq >/dev/null 2>&1 || return 0
	[[ -f "$isolated_auth" ]] || return 0
	[[ -f "$pool_file" ]] || return 0
	[[ -x "$oauth_helper" ]] || return 0

	# Extract BOTH the email and access token currently written in the
	# isolated auth for this provider. build_auth_entry (in
	# oauth-pool-lib/_common.py) writes only {type, refresh, access, expires}
	# on rotation — NOT email. So after the first rotation, the isolated
	# auth.json has no email field and the previous email-only lookup here
	# returned early, defeating the rotation on every subsequent dispatch.
	# (CodeRabbit review #4135227617, verified against live production
	# ~/.local/share/opencode/auth.json 2026-04-19.)
	local current_email current_access
	current_email=$(jq -r --arg p "$provider" '.[$p].email // empty' "$isolated_auth" 2>/dev/null || true)
	current_access=$(jq -r --arg p "$provider" '.[$p].access // empty' "$isolated_auth" 2>/dev/null || true)
	[[ -n "$current_email" || -n "$current_access" ]] || return 0

	# Look up the account in the shared pool. Try email first (most common —
	# interactive auth with email was copied to isolated at worker startup).
	# Fall back to access-token match when email is absent (isolated auth
	# was already rotated at least once, dropping email per build_auth_entry).
	local pool_match=""
	if [[ -n "$current_email" ]]; then
		pool_match=$(jq -c --arg p "$provider" --arg e "$current_email" \
			'.[$p] | map(select(.email == $e)) | .[0] // empty' "$pool_file" 2>/dev/null || true)
	fi
	if [[ -z "$pool_match" && -n "$current_access" ]]; then
		pool_match=$(jq -c --arg p "$provider" --arg a "$current_access" \
			'.[$p] | map(select(.access == $a)) | .[0] // empty' "$pool_file" 2>/dev/null || true)
	fi
	[[ -n "$pool_match" ]] || return 0

	local cooldown_until now_ms identity_label
	cooldown_until=$(printf '%s' "$pool_match" | jq -r '.cooldownUntil // 0' 2>/dev/null || echo 0)
	[[ -n "$cooldown_until" ]] || cooldown_until=0
	# Log-friendly identity: prefer email, fall back to a short access-token
	# fingerprint. Never log full access tokens (they are secrets).
	if [[ -n "$current_email" ]]; then
		identity_label="$current_email"
	else
		identity_label="access=${current_access:0:8}…"
	fi
	now_ms=$(($(date +%s) * 1000))

	# Only rotate when cooldown is still active (in the future).
	if [[ "$cooldown_until" -gt "$now_ms" ]]; then
		local isolated_dir
		isolated_dir="$(dirname "$(dirname "$isolated_auth")")"
		print_info "[lifecycle] pre_dispatch_rotate: ${provider} account=${identity_label} in cooldown; rotating isolated auth (dir=${isolated_dir})"
		# XDG_DATA_HOME is already exported by caller; passing it explicitly here
		# makes the intent explicit in logs and protects against env stripping.
		if XDG_DATA_HOME="$isolated_dir" "$oauth_helper" rotate "$provider" >/dev/null 2>&1; then
			local new_email new_access new_label
			new_email=$(jq -r --arg p "$provider" '.[$p].email // empty' "$isolated_auth" 2>/dev/null || echo "")
			new_access=$(jq -r --arg p "$provider" '.[$p].access // empty' "$isolated_auth" 2>/dev/null || echo "")
			if [[ -n "$new_email" ]]; then
				new_label="$new_email"
			elif [[ -n "$new_access" ]]; then
				new_label="access=${new_access:0:8}…"
			else
				new_label="$_HRW_STATUS_UNKNOWN"
			fi
			print_info "[lifecycle] pre_dispatch_rotate: ${provider} ${identity_label} -> ${new_label}"
		else
			print_warning "[lifecycle] pre_dispatch_rotate failed for ${provider}; continuing with current account"
		fi
	fi

	return 0
}

#######################################
# _launch_rate_limit_fast_monitor: background 30s sentinel that detects
# Anthropic 429 / provider-overload patterns on the FIRST API call and
# kills the worker cleanly before the 20-min opencode retry zombie forms.
#
# GH#21578 / t3021 — Three simultaneous workers were killed at t=20min
# (exit 143, duration_ms ~1.2M) because opencode silently retried a 429
# for the full slot lifetime. Each zombie blocked one dispatch slot.
#
# Strategy: poll output_file every 5s for monitor_window seconds (default 30).
# If rate-limit / HTTP-5xx patterns appear AND the worker produced no LLM
# activity yet (JSON events), SIGTERM the worker, write exit_code=0 and the
# .rate_limit_fast sentinel next to exit_code_file, then exit.
# _execute_run_attempt reads the sentinel and routes to exit 80, which
# cmd_run handles without incrementing the fast-fail / NMR counter.
#
# Args:
#   $1 output_file      — tee'd worker output file to monitor
#   $2 worker_pid       — the worker subshell PID to kill on detection
#   $3 exit_code_file   — path for writing exit_code=0 + creating sentinel
#   $4 monitor_window   — seconds to watch (default: 30)
#
# Returns: 0 always (launched in background; caller captures PID via $!)
#######################################
_launch_rate_limit_fast_monitor() {
	local output_file="$1"
	local worker_pid="$2"
	local exit_code_file="$3"
	local monitor_window="${4:-30}"
	local poll_interval=5

	(
		set +e
		local elapsed=0
		local sentinel="${exit_code_file}.rate_limit_fast"

		while [[ "$elapsed" -lt "$monitor_window" ]]; do
			sleep "$poll_interval"
			elapsed=$((elapsed + poll_interval))

			# Exit cleanly if the worker already finished on its own.
			if ! kill -0 "$worker_pid" 2>/dev/null; then
				return 0
			fi

			# Only fire if no LLM activity has been produced yet.
			# If the model already started working (step_start, tool, etc.),
			# this is not a dead-on-arrival rate limit — let the watchdog handle it.
			if [[ -f "$output_file" ]] && grep -q '"type"' "$output_file" 2>/dev/null; then
				return 0
			fi

			# Check for rate-limit / provider-overload patterns in the output.
			# Patterns mirror classify_failure_reason() in headless-runtime-lib.sh.
			if [[ -f "$output_file" ]] && \
				grep -qiE '(429|rate.?limit|too.many.requests|overloaded|service.unavailable|internal.server.error|50[0-9] )' \
				"$output_file" 2>/dev/null; then
				# Kill the worker cleanly — this is a transient API condition.
				kill -TERM "$worker_pid" 2>/dev/null || true
				sleep 2
				kill -0 "$worker_pid" 2>/dev/null && kill -KILL "$worker_pid" 2>/dev/null || true
				# Signal _execute_run_attempt to route as rate_limit_fast (exit 80).
				printf '%s' "0" >"$exit_code_file" 2>/dev/null || true
				printf '%s' "1" >"$sentinel" 2>/dev/null || true
				return 0
			fi
		done
		return 0
	) &
	printf '%s' "$!"
	return 0
}

# =============================================================================
# Claude CLI invocation
# =============================================================================

# _invoke_claude: run the claude CLI command and capture output.
# Same interface as _invoke_opencode for interchangeability.
# Args: output_file exit_code_file cmd_args...
_invoke_claude() {
	local output_file="$1"
	local exit_code_file="$2"
	shift 2
	local -a cmd=("$@")

	(
		set +e
		if [[ -x "$SANDBOX_EXEC_HELPER" && "${AIDEVOPS_HEADLESS_SANDBOX_DISABLED:-}" != "1" ]]; then
			local passthrough_csv
			passthrough_csv="$(build_sandbox_passthrough_csv)"
			if [[ -n "$passthrough_csv" ]]; then
				"$SANDBOX_EXEC_HELPER" run --timeout "$HEADLESS_SANDBOX_TIMEOUT_DEFAULT" --allow-secret-io --passthrough "$passthrough_csv" -- "${cmd[@]}" 2>&1 | tee "$output_file"
			else
				"$SANDBOX_EXEC_HELPER" run --timeout "$HEADLESS_SANDBOX_TIMEOUT_DEFAULT" --allow-secret-io -- "${cmd[@]}" 2>&1 | tee "$output_file"
			fi
			printf '%s' "${PIPESTATUS[0]}" >"$exit_code_file"
		else
			if [[ "${AIDEVOPS_HEADLESS_SANDBOX_DISABLED:-}" == "1" ]]; then
				print_info "AIDEVOPS_HEADLESS_SANDBOX_DISABLED=1 — using bare exec (no privilege isolation) (GH#20146 audit)"
			fi
			"${cmd[@]}" 2>&1 | tee "$output_file"
			printf '%s' "${PIPESTATUS[0]}" >"$exit_code_file"
		fi
	) || true
	return 0
}

# =============================================================================
# Output preservation and classification
# =============================================================================

#######################################
# t2119: Preserve a worker output file on no_activity failure so operators
# can diagnose why the runtime exited without ever producing JSON events.
#
# Before t2119, _handle_run_result unconditionally `rm -f "$output_file"`
# on the no_activity path, erasing the only forensic evidence (opencode
# stderr via tee, plugin startup log lines, sandbox exec trace). This
# left the residual 30s failures observed in the t2116 session with zero
# diagnostic surface.
#
# Strategy: move (not copy — keeps disk usage bounded) the output file
# to ~/.aidevops/logs/worker-no-activity/<session>-<ts>.log. Size-cap
# each preserved file to 256KB (worker output files rarely exceed this;
# truncation is fine for forensic purposes). Retention-cap the directory
# to the 50 most recent files so the log directory doesn't grow
# unbounded on a looping failure.
#
# Best-effort throughout — a preservation failure must never propagate
# into the caller's error-handling path. The goal is forensics, not
# hard-guaranteed persistence.
#
# Args:
#   $1 - output_file path
#   $2 - session_key (e.g. issue-19114 or pulse)
#   $3 - model (for filename disambiguation; slashes stripped)
#######################################
_preserve_no_activity_output() {
	local output_file="$1"
	local session_key="${2:-unknown}"
	local model="${3:-unknown}"

	if [[ -z "$output_file" || ! -f "$output_file" ]]; then
		return 0
	fi

	local diag_dir="${HOME}/.aidevops/logs/worker-no-activity"
	if ! mkdir -p "$diag_dir" 2>/dev/null; then
		# Fall back to the original delete behaviour if the diagnostic
		# directory can't be created — we must not keep tmp files around.
		rm -f "$output_file" 2>/dev/null || true
		return 0
	fi

	# Sanitize session + model for use in a filename.
	local safe_session safe_model
	safe_session=$(printf '%s' "$session_key" | tr '/ ' '__' | tr -cd 'A-Za-z0-9._-' | cut -c1-64)
	safe_model=$(printf '%s' "$model" | tr '/ ' '__' | tr -cd 'A-Za-z0-9._-' | cut -c1-32)
	[[ -n "$safe_session" ]] || safe_session="$_HRW_STATUS_UNKNOWN"
	[[ -n "$safe_model" ]] || safe_model="$_HRW_STATUS_UNKNOWN"

	local ts
	ts=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%s)
	local dest="${diag_dir}/${ts}-${safe_session}-${safe_model}.log"

	# Size-cap: take the first 256KB of the output. For the no_activity
	# failure mode the interesting content (plugin init errors, opencode
	# startup logs, migration output, auth refresh messages) always
	# lands in the first few KB; anything past 256KB is noise.
	local max_bytes=262144
	if head -c "$max_bytes" "$output_file" >"$dest" 2>/dev/null; then
		local orig_size
		orig_size=$(wc -c <"$output_file" 2>/dev/null | tr -d ' ') || orig_size=0
		if [[ "$orig_size" -gt "$max_bytes" ]]; then
			printf '\n\n[...t2119 TRUNCATED at %d bytes, original %d bytes...]\n' \
				"$max_bytes" "$orig_size" >>"$dest" 2>/dev/null || true
		fi
	fi

	rm -f "$output_file" 2>/dev/null || true

	# Retention cap: keep the 50 most recent preserved files.
	# ls -t returns newest first; tail -n +51 selects everything beyond the cap.
	# Using find -print0 | sort would be more robust but ls is enough for
	# our flat directory of predictable filenames.
	local keep=50
	local prune_list
	prune_list=$(cd "$diag_dir" 2>/dev/null && ls -1t -- *.log 2>/dev/null | tail -n +$((keep + 1))) || prune_list=""
	if [[ -n "$prune_list" ]]; then
		while IFS= read -r _victim; do
			[[ -n "$_victim" ]] || continue
			rm -f "${diag_dir}/${_victim}" 2>/dev/null || true
		done <<<"$prune_list"
	fi

	return 0
}

# =============================================================================
# Worker output classification
# =============================================================================

#######################################
# Detect whether a worker produced any tangible output.
#
# Checks three independent signals. Returns 0 (true — has output) if ANY
# signal is present; returns 1 (false — zero output) only when ALL are absent.
#
# Args:
#   $1 - session_key (e.g. "issue-20721")
#   $2 - work_dir    (worktree root; must be a git repo)
#
# Signals checked (in order of cheapness):
#   1. Commits on feature branch beyond remote default branch
#      (git rev-list --count origin/main..HEAD > 0; falls back to origin/master)
#   2. Branch pushed to remote
#      (git ls-remote origin refs/heads/<branch> is non-empty)
#   3. PR linked to this issue via gh
#      (gh pr list --search "<issue_number>" returns at least one result)
#
# Design principle — fail-open: every check that errors (no remote, no gh,
# detached HEAD, network failure) returns 0 so false-negatives are impossible.
# Only a confirmed absence of all three signals triggers a noop classification.
#######################################
# _worker_produced_output — classify worker output quality (GH#20819)
#
# Returns one of three classification strings via stdout:
#   "pr_exists"     — PR confirmed, or fail-open (cannot evaluate signals)
#   "branch_orphan" — branch pushed + commits exist BUT no PR found
#                     (requires DISPATCH_REPO_SLUG + gh to confirm absence)
#   "noop"          — no commits, no pushed branch, no PR
#
# Fail-open semantics are preserved: any condition that prevents confident
# signal evaluation echoes "pr_exists" so false-negatives (real work
# misclassified as orphan or noop) are impossible.  Only a confirmed
# absence of all signals (noop) or a confirmed branch-without-PR
# (branch_orphan) triggers those classifications.
#
# Always returns 0. Callers capture stdout:
#   local classification
#   classification=$(_worker_produced_output "$session_key" "$work_dir")
#######################################
_worker_produced_output() {
	local session_key="$1"
	local work_dir="$2"

	# Only applies to worker sessions (issue-* key pattern)
	if [[ "$session_key" != issue-* ]]; then
		printf 'pr_exists'  # fail-open for non-worker sessions
		return 0
	fi

	# Bail if work_dir is not a valid git repo — fail-open
	if [[ -z "$work_dir" ]] || ! git -C "$work_dir" rev-parse --git-dir >/dev/null 2>&1; then
		printf 'pr_exists'  # fail-open: cannot evaluate signals
		return 0
	fi

	# Signal 1: commits on feature branch beyond origin/main (fallback: master)
	local has_commits=0
	local commit_count=0
	commit_count=$(git -C "$work_dir" rev-list --count "origin/main..HEAD" 2>/dev/null || true)
	[[ "$commit_count" =~ ^[0-9]+$ ]] || commit_count=0
	if [[ "$commit_count" -gt 0 ]]; then
		has_commits=1
	else
		# Signal 1b: fallback for origin/master default branch
		commit_count=$(git -C "$work_dir" rev-list --count "origin/master..HEAD" 2>/dev/null || true)
		[[ "$commit_count" =~ ^[0-9]+$ ]] || commit_count=0
		[[ "$commit_count" -gt 0 ]] && has_commits=1
	fi

	# Signal 2: branch pushed to remote
	# Default-branch guard (t2899): when HEAD ends on the repo's default branch
	# (main/master), Signal 2 ALWAYS matches because the default branch exists
	# on the remote — every worker that exits without checking out a feature
	# branch was previously misclassified as branch_orphan. Resolve the default
	# branch via origin/HEAD symbolic-ref (with env + literal fallback) and skip
	# Signal 2 entirely when branch_name matches it. The signal is meaningless
	# on default branches: there is no orphan branch to recover.
	local has_pushed_branch=0
	local branch_name=""
	local default_branch=""
	branch_name=$(git -C "$work_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
	default_branch=$(git -C "$work_dir" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null \
		| sed 's|^origin/||' || true)
	[[ -z "$default_branch" ]] && default_branch="${DISPATCH_REPO_DEFAULT_BRANCH:-main}"
	if [[ -n "$branch_name" && "$branch_name" != "HEAD" && "$branch_name" != "$default_branch" ]]; then
		local remote_ref=""
		remote_ref=$(git -C "$work_dir" ls-remote origin "refs/heads/$branch_name" 2>/dev/null || true)
		[[ -n "$remote_ref" ]] && has_pushed_branch=1
	fi

	# Early exit: no commits, no pushed branch → definitely noop (no PR check needed)
	# Also covers the t2899 default-branch case: HEAD on main with no/any commits
	# but no feature branch pushed → noop, not branch_orphan.
	if [[ "$has_commits" -eq 0 && "$has_pushed_branch" -eq 0 ]]; then
		printf 'noop'
		return 0
	fi
	# t2899: HEAD on default branch with commits ahead but no feature branch pushed.
	# This is "worker landed on main with local commits" — not an orphan branch.
	# Without a feature branch to recover, Signal 1 alone cannot produce a meaningful
	# branch_orphan classification, so collapse to noop.
	if [[ "$has_pushed_branch" -eq 0 && "$branch_name" == "$default_branch" ]]; then
		printf 'noop'
		return 0
	fi

	# Signal 3: PR linked to this issue (requires gh and DISPATCH_REPO_SLUG)
	# Only reachable when Signal 1 or 2 is present — disambiguates pr_exists vs branch_orphan.
	local issue_number=""
	issue_number=$(printf '%s' "$session_key" | grep -oE '[0-9]+$' || true)
	local repo_slug="${DISPATCH_REPO_SLUG:-}"
	if [[ -n "$issue_number" && -n "$repo_slug" ]]; then
		local pr_count=0
		pr_count=$(gh pr list --repo "$repo_slug" --search "$issue_number" \
			--json number --jq 'length' 2>/dev/null || true)
		[[ "$pr_count" =~ ^[0-9]+$ ]] || pr_count=0
		if [[ "$pr_count" -gt 0 ]]; then
			printf 'pr_exists'
			return 0
		fi
		# PR confirmed absent: branch/commits exist but no PR → orphan (GH#20819)
		printf 'branch_orphan'
		return 0
	fi

	# Cannot verify PR status (no repo_slug or issue_number) — fail-open.
	# Treat branch/commits as pr_exists: cannot confirm orphan without PR check.
	printf 'pr_exists'
	return 0
}

# =============================================================================
# Orphan handling
# =============================================================================

#######################################
# _increment_orphan_count_stat — increment worker_branch_orphan_count in pulse-stats.json
#
# Uses pulse_stats_increment if available (pulse-stats-helper.sh is sourced
# in pulse-wrapper.sh context); otherwise does an inline jq atomic update
# using the same timestamp-array format for consistency.
#
# Non-fatal: any file/jq failure is silently ignored.
#######################################
_increment_orphan_count_stat() {
	if declare -F pulse_stats_increment >/dev/null 2>&1; then
		pulse_stats_increment "worker_branch_orphan_count" 2>/dev/null || true
		return 0
	fi
	# Inline fallback: timestamp-array format (matches pulse-stats-helper.sh schema)
	local _stats_file="${PULSE_STATS_FILE:-${HOME}/.aidevops/logs/pulse-stats.json}"
	local _stats_dir
	_stats_dir="$(dirname "$_stats_file")"
	[[ -d "$_stats_dir" ]] || mkdir -p "$_stats_dir" 2>/dev/null || return 0
	[[ -f "$_stats_file" ]] || printf '{"counters":{}}\n' >"$_stats_file" 2>/dev/null || return 0
	local _ts _tmp
	_ts=$(date +%s 2>/dev/null) || _ts=0
	# t2997: drop .json — XXXXXX must be at end for BSD mktemp.
	_tmp=$(mktemp "${TMPDIR:-/tmp}/pulse-stats-orphan-XXXXXX") || return 0
	jq --argjson ts "$_ts" \
		'.counters.worker_branch_orphan_count += [$ts]' \
		"$_stats_file" >"$_tmp" 2>/dev/null \
		|| { rm -f "$_tmp"; return 0; }
	mv "$_tmp" "$_stats_file" 2>/dev/null || rm -f "$_tmp"
	return 0
}

#######################################
# _handle_worker_branch_orphan — recover from worker_branch_orphan state (GH#20819)
#
# Called from _cmd_run_finish when _worker_produced_output returns "branch_orphan":
# the worker pushed commits/branch but exited before opening a PR.
#
# Actions:
#   1. Increments worker_branch_orphan_count in pulse-stats.json (always)
#   2. Calls _attempt_orphan_recovery_pr to open a PR (GH#20819)
#   3. On PR success  → releases claim as "worker_complete" (audit note)
#   4. On PR failure  → releases claim as "worker_branch_orphan" + posts
#      structured ops comment on the issue so next dispatch can pick up
#
# Args: $1=session_key, $2=work_dir
#######################################
_handle_worker_branch_orphan() {
	local session_key="$1"
	local work_dir="$2"

	local branch_name=""
	branch_name=$(git -C "$work_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
	local repo_slug="${DISPATCH_REPO_SLUG:-}"
	local issue_number=""
	issue_number=$(printf '%s' "$session_key" | grep -oE '[0-9]+$' || true)

	# t2899: extended diagnostic — surface what the worker actually produced so
	# the next regression in this classifier is debuggable from a single log line.
	# target_branch is the branch the worker was DISPATCHED to operate on
	# (set by the dispatch path via WORKER_TARGET_BRANCH env if present);
	# final_head is the HEAD SHA the worker exited on; ahead_count is commits
	# ahead of origin/$base_branch (DISPATCH_REPO_DEFAULT_BRANCH, fallback to
	# origin/master when the primary ref is missing); work_dir is the worktree path.
	local target_branch="${WORKER_TARGET_BRANCH:-<unset>}"
	local final_head=""
	final_head=$(git -C "$work_dir" rev-parse --short=12 HEAD 2>/dev/null || printf '<unreadable>')
	local ahead_count=0
	local base_branch="${DISPATCH_REPO_DEFAULT_BRANCH:-main}"
	local rev_output=""
	# Fallback to master only when the primary ref is MISSING (non-zero exit),
	# not when the count happens to be zero (worker exited on default branch).
	if rev_output=$(git -C "$work_dir" rev-list --count "origin/${base_branch}..HEAD" 2>/dev/null); then
		ahead_count=$rev_output
	else
		ahead_count=$(git -C "$work_dir" rev-list --count "origin/master..HEAD" 2>/dev/null || echo 0)
	fi
	[[ "$ahead_count" =~ ^[0-9]+$ ]] || ahead_count=0

	print_info "[lifecycle] worker_branch_orphan session=${session_key} branch=${branch_name:-<none>} target_branch=${target_branch} final_head=${final_head} ahead_count=${ahead_count} work_dir=${work_dir:-<unset>}"

	# Always increment counter — failure or success
	_increment_orphan_count_stat

	if _attempt_orphan_recovery_pr "$session_key" "$work_dir" "$branch_name" "$repo_slug"; then
		print_info "[lifecycle] Orphan PR auto-created for session=${session_key}"
		_release_dispatch_claim "$session_key" "worker_complete"
	else
		print_info "[lifecycle] Orphan recovery failed for session=${session_key}"
		_release_dispatch_claim "$session_key" "worker_branch_orphan"
		# Post structured ops comment so the next dispatch knows what happened
		if [[ -n "$issue_number" && -n "$repo_slug" && -n "$branch_name" ]]; then
			local _ops_comment
			# shellcheck disable=SC2016 # backticks are literal markdown, not command substitution
			_ops_comment=$(printf '<!-- ops:start -->\nWORKER_BRANCH_ORPHAN branch=%s session=%s ts=%s\n\nThis worker pushed branch `%s` but no PR could be opened automatically. To recover, open a PR manually:\n\n```\ngh pr create --head %s --base main --repo %s\n```\n<!-- ops:end -->' \
				"$branch_name" "$session_key" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
				"$branch_name" "$branch_name" "$repo_slug")
			gh api "repos/${repo_slug}/issues/${issue_number}/comments" \
				--method POST \
				--field body="$_ops_comment" \
				>/dev/null 2>&1 || true
		fi
	fi
	return 0
}

# =============================================================================
# Run lifecycle — prepare, finish, retry, detach
# =============================================================================

_cmd_run_finish() {
	local session_key="$1"
	local ledger_status="$2"
	# work_dir is optional ($3). When present and ledger_status != "fail",
	# _worker_produced_output() classifies tangible output to distinguish
	# worker_complete, worker_branch_orphan, and worker_noop (GH#20721, GH#20819).
	local work_dir="${3:-}"

	# Release the dispatch claim so the issue is immediately available for
	# re-dispatch (next 2-min pulse cycle) instead of waiting for the
	# 30-min DISPATCH_COMMENT_MAX_AGE TTL to expire.
	#
	# Both success and failure paths post CLAIM_RELEASED — completion signal
	# consistency matters (GH#19836 follow-up). On success, the worker may
	# have exited without creating a PR (e.g., premise falsified and issue
	# closed, or worker completed an out-of-PR action). Relying only on
	# "PR with Closes #" or MERGE_SUMMARY to clear the claim leaves a 30-min
	# dead-zone where the issue is stuck with no audit trail. The
	# dispatch-dedup guard already treats any CLAIM_RELEASED as authoritative
	# (dispatch-dedup-helper.sh:1044), so this is safe — if a worker DID
	# create a PR with Closes, the PR-based dedup signal still wins and the
	# CLAIM_RELEASED comment is redundant operational metadata.
	if [[ "$ledger_status" == "$_HRW_STATUS_FAIL" ]]; then
		_release_dispatch_claim "$session_key" "worker_failed"

		# Classify crash type from worker session state.
		# _run_result_label is set by _handle_run_result:
		#   "premature_exit" = model had activity but no completion signal
		#   "no_activity"    = no LLM output at all
		#   "watchdog_stall_continue" = stall with prior activity (passive kill)
		#   "watchdog_stall_killed"   = stall + elapsed ≥ hard-kill cap (proactive)
		#   other            = provider/infra failures
		local crash_type=""
		case "${_run_result_label:-}" in
		premature_exit | watchdog_stall_continue | watchdog_stall_killed)
			# Model attempted real work (read files, created worktree) but
			# couldn't produce commits/PR. This is "overwhelmed" — the model
			# tried and failed due to task complexity, not infra issues.
			crash_type="overwhelmed"
			;;
		no_activity)
			# No LLM output at all — infra/setup failure
			crash_type="no_work"
			;;
		*)
			# Provider errors, rate limits, auth failures — not a model
			# capability issue, don't classify for escalation purposes
			crash_type=""
			;;
		esac

		# Self-report to the fast-fail counter so tier escalation fires
		# immediately instead of waiting 30+ min for the pulse to discover
		# the orphaned assignment. Uses the failure reason from the retry
		# loop if available, otherwise defaults to "worker_failed".
		_report_failure_to_fast_fail "$session_key" "${_run_failure_reason:-worker_failed}" "$crash_type"
	elif [[ "$ledger_status" == "rate_limit_fast" ]]; then
		# GH#21578 / t3021: Transient API rate limit detected within first 30s.
		# Release the dispatch claim so the issue re-queues on the next pulse cycle.
		# Do NOT call _report_failure_to_fast_fail — this is a transient API
		# condition (Anthropic 429/overload), not a model capability failure.
		# NMR backoff would incorrectly penalise the issue for an infrastructure blip.
		# Metric already recorded by _execute_run_attempt with result=rate_limit_fast.
		_release_dispatch_claim "$session_key" "rate_limit_transient"
	else
		# GH#20721 + GH#20819: Classify worker output quality.
		# _worker_produced_output echoes one of three classifications:
		#   noop          — no commits, no branch, no PR → fast-fail
		#   branch_orphan — branch pushed but no PR → auto-recover
		#   pr_exists     — PR confirmed, or fail-open → worker_complete
		#
		# Fail-open semantics are preserved: when signals cannot be evaluated
		# (no git repo, no gh, no remote) the classification is "pr_exists",
		# so false-negatives (legit work misclassified) are impossible.
		# Classify output and route to the appropriate release path.
		# _release_needed tracks whether the normal success release is still
		# required; noop and branch_orphan handlers release the claim themselves.
		local _release_needed=1
		if [[ -n "$work_dir" ]]; then
			local _output_class="pr_exists"
			_output_class=$(_worker_produced_output "$session_key" "$work_dir")
			case "$_output_class" in
			noop)
				print_info "[lifecycle] worker_noop session=$session_key — zero commits, no pushed branch, no PR"
				_release_dispatch_claim "$session_key" "worker_noop"
				_report_failure_to_fast_fail "$session_key" "worker_noop_zero_output" "no_work"
				_release_needed=0
				;;
			branch_orphan)
				# Branch pushed but no PR — attempt auto-recovery (GH#20819)
				_handle_worker_branch_orphan "$session_key" "$work_dir"
				_release_needed=0
				;;
			esac
		fi
		if [[ "$_release_needed" -eq 1 ]]; then
			# pr_exists or fail-open: normal success path.
			# Post CLAIM_RELEASED with reason=worker_complete so the audit
			# trail shows the full lifecycle even when no PR was created.
			_release_dispatch_claim "$session_key" "worker_complete"
		fi
	fi

	_update_dispatch_ledger "$session_key" "$ledger_status"
	_release_session_lock "$session_key"
	trap - EXIT
	return 0
}

_cmd_run_prepare() {
	local session_key="$1"
	local work_dir="$2"

	# t2983 Fix C: Worker-role guard — WORKER_WORKTREE_PATH must be set.
	# After GH#21353 (Fix A), the dispatcher never launches a worker when
	# pre-creation fails. If WORKER_WORKTREE_PATH is somehow unset here despite
	# WORKER_ISSUE_NUMBER being set, a dispatcher bug bypassed pre-creation.
	# Abort immediately rather than proceeding in the canonical repo on main.
	if [[ -n "${WORKER_ISSUE_NUMBER:-}" && -z "${WORKER_WORKTREE_PATH:-}" ]]; then
		printf '[fatal] WORKER_WORKTREE_PATH unset — pre-creation skipped or failed silently; aborting per t2983 Fix C\n' >&2
		return 1
	fi

	# GH#20542: Export DISPATCH_REPO_SLUG BEFORE arming the EXIT trap so
	# _release_dispatch_claim always has a non-empty slug, even when the
	# process exits between prepare and _execute_run_attempt (e.g. under
	# set -euo pipefail). Role-agnostic: the git extraction is cheap and
	# _release_dispatch_claim silently no-ops when issue_number is absent.
	local _prepare_repo_slug=""
	_prepare_repo_slug=$(git -C "$work_dir" remote get-url origin 2>/dev/null \
		| sed -E 's|.*github\.com[:/]||; s|\.git$||' || true)
	if [[ -n "$_prepare_repo_slug" ]]; then
		export DISPATCH_REPO_SLUG="$_prepare_repo_slug"
	fi

	# GH#6538: Acquire a session-key lock to prevent duplicate workers.
	# The pulse (or any caller) may dispatch the same session-key twice in
	# rapid succession — before the first worker appears in process lists.
	# The lock file acts as an immediate dedup guard: the second invocation
	# sees the first's PID and exits without spawning a sandbox process.
	if ! _acquire_session_lock "$session_key"; then
		return 2
	fi
	# GH#20564: Use _exit_trap_handler to classify the exit reason
	# (crash_during_startup / crash_during_execution / signal_killed:<N> / clean)
	# instead of emitting a fixed 'process_exit' reason for all abnormal exits.
	# SC2064: session_key is intentionally baked in at trap-set time.
	# shellcheck disable=SC2064
	trap "_exit_trap_handler '$session_key'" EXIT

	# GH#20564: Record worker start time in milliseconds for exit trap classifier.
	# classify_worker_exit uses this to distinguish crash_during_startup (no
	# session created since start) from crash_during_execution (session found).
	# Uses the same python3 ms-epoch pattern as _execute_run_attempt metrics.
	_WORKER_START_EPOCH_MS=$(python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null || printf '%s' "0")

	# t2923: Expose worktree path to exit trap handler so _push_wip_commits_on_exit
	# can push any local-only commits before the worker releases its claim.
	export _WORKER_WORKTREE_PATH="$work_dir"

	# GH#6696: Register this dispatch in the in-flight ledger so the pulse
	# can detect workers that haven't created PRs yet. The ledger bridges
	# the 10-15 minute gap between dispatch and PR creation.
	_register_dispatch_ledger "$session_key" "$work_dir"
	return 0
}

# shellcheck disable=SC2154 # _run_should_retry, _run_failure_reason set by caller in cmd_run loop
_cmd_run_prepare_retry() {
	local role="$1"
	local session_key="$2"
	local model_override="$3"
	local attempt="$4"
	local max_attempts="$5"
	local selected_model="$6"
	local attempt_exit="$7"
	local provider=""
	local next_model=""

	cmd_run_action="retry"
	cmd_run_next_model="$selected_model"

	# Retry only in auto-selection mode and only when attempts remain.
	if [[ -n "$model_override" || "$attempt" -ge "$max_attempts" ]]; then
		_cmd_run_finish "$session_key" "$_HRW_STATUS_FAIL"
		return "$attempt_exit"
	fi

	if [[ "$_run_should_retry" == "1" ]]; then
		print_warning "Retrying ${selected_model} once after pool account rotation"
		return 0
	fi

	if [[ "$_run_failure_reason" != "auth_error" && "$_run_failure_reason" != "rate_limit" ]]; then
		_cmd_run_finish "$session_key" "$_HRW_STATUS_FAIL"
		return "$attempt_exit"
	fi

	provider=$(extract_provider "$selected_model")
	next_model=$(choose_model "$role" "") || {
		_cmd_run_finish "$session_key" "$_HRW_STATUS_FAIL"
		return "$attempt_exit"
	}
	print_warning "$provider $_run_failure_reason detected; retrying with alternate provider model $next_model"
	cmd_run_action="switch"
	cmd_run_next_model="$next_model"
	return 0
}

_detach_worker() {
	local session_key="$1"
	shift
	local log_file="/tmp/worker-${session_key}.log"
	print_info "Detaching worker (log: $log_file)"
	(
		# Detach from terminal and redirect all output
		exec </dev/null >"$log_file" 2>&1
		# Re-invoke the script without --detach to avoid recursion
		local -a filtered_args=()
		for arg in "$@"; do
			[[ "$arg" == "--detach" ]] && continue
			filtered_args+=("$arg")
		done
		"$0" run "${filtered_args[@]}"
	) &
	local child_pid=$!
	print_info "Dispatched PID: $child_pid"
	return 0
}

# =============================================================================
# Stall cap helper (GH#20681)
# =============================================================================

#######################################
# Check whether per-session watchdog stall caps are exceeded.
#
# Two independent triggers — whichever fires first stops the session:
#   1. Count cap: number of stall events > WORKER_STALL_CONTINUE_MAX
#   2. Cumulative time cap: total stall seconds >= WORKER_STALL_CUMULATIVE_MAX_S
#
# Args:
#   $1 - current stall event count (integer)
#   $2 - cumulative stall seconds (integer)
#   $3 - max stall count (WORKER_STALL_CONTINUE_MAX, default 3)
#   $4 - max cumulative seconds (WORKER_STALL_CUMULATIVE_MAX_S, default 1800)
#
# Returns: 0 if cap exceeded (caller should kill), 1 if within cap (can continue)
#######################################
_stall_session_cap_exceeded() {
	local count="$1"
	local cumulative_s="$2"
	local max_count="${3:-3}"
	local max_cumulative_s="${4:-1800}"

	[[ "$count" -gt "$max_count" ]] && return 0
	[[ "$cumulative_s" -ge "$max_cumulative_s" ]] && return 0
	return 1
}
