#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-dispatch-worker-launch.sh — Worker launch helpers — assignment, log setup, tier/model resolution, worktree pre-creation, nohup launch, post-launch hooks, and thin orchestrator.
#
# Extracted from pulse-dispatch-core.sh (GH#18832) to bring that file
# below the 2000-line simplification gate.
#
# This module is sourced by pulse-dispatch-core.sh. Depends on
# shared-constants.sh and worker-lifecycle-common.sh being sourced first.
#
# Functions in this module (in source order):
#   - _dlw_assign_and_label
#   - _dlw_setup_worker_log
#   - _dlw_resolve_tier_and_model
#   - _dlw_precreate_worktree
#   - _dlw_nohup_launch
#   - _dlw_post_launch_hooks
#   - _dispatch_launch_worker

[[ -n "${_PULSE_DISPATCH_WORKER_LAUNCH_LOADED:-}" ]] && return 0
_PULSE_DISPATCH_WORKER_LAUNCH_LOADED=1

#######################################
# Post-clearance worker launch for dispatch_with_dedup.
# Extracted from dispatch_with_dedup (t1999, Phase 12) to reduce the
# parent function to a thin orchestrator.
#
# Executes all post-clearance steps after _dispatch_dedup_check_layers
# has confirmed the issue is safe to dispatch:
#   - Issue edit: replace assignees, add status:queued + origin:worker
#   - Worker log file setup (per-issue temp log, GH#14483)
#   - Model/tier resolution (round-robin, t1997)
#   - Issue + linked PR lock (t1894/t1934)
#   - Git pull to latest remote commit (GH#17584)
#   - Worktree pre-creation for the worker (5-8 tool call savings)
#   - Worker command construction + nohup launch (GH#17549)
#   - Stagger delay (SQLite contention, GH#17549)
#   - Dispatch ledger registration (tier telemetry)
#   - Deterministic dispatch comment (GH#15317)
#   - Claim comment audit trail retention (GH#17503)
#
# Arguments:
#    $1 - issue_number
#    $2 - repo_slug (owner/repo)
#    $3 - dispatch_title
#    $4 - issue_title
#    $5 - self_login (dispatching runner login)
#    $6 - repo_path (local path to the repo)
#    $7 - prompt (worker prompt string)
#    $8 - session_key
#    $9 - model_override (empty = auto-select via round-robin)
#   $10 - issue_meta_json (pre-fetched JSON: number,title,state,labels,assignees)
#
# Dynamic scoping: reads/writes _claim_comment_id from the calling
# dispatch_with_dedup frame (set by check_dispatch_dedup, GH#15317).
# Do NOT declare local _claim_comment_id here — it must remain in the
# caller's scope so the value survives the function return.
#
# Exit codes:
#   0 - worker launched successfully
#   non-zero - launch failed (logged to LOGFILE)
#######################################
#######################################
# Atomically swap issue assignment to the dispatching runner and apply
# status labels for a queued worker (GH#17777, t2033).
#
# Previous behavior only added self (--add-assignee), leaving the original
# assignee (typically the issue creator) co-assigned. This created ambiguity
# about ownership and confused dedup layer 6 (is_assigned) when status:queued
# made passive owner assignments appear active.
#
# t2033: use set_issue_status to atomically clear sibling status:* labels.
# Before t2033, this call site added status:queued without removing
# status:available — #18444/#18454/#18455 accumulated both labels and
# broke t2008 stale-recovery tick counting.
#
# Arguments: issue_number, repo_slug, self_login, issue_meta_json
#######################################
_dlw_assign_and_label() {
	local issue_number="$1"
	local repo_slug="$2"
	local self_login="$3"
	local issue_meta_json="$4"

	local -a _extra_flags=(--add-assignee "$self_login" --add-label "origin:worker")
	local _prev_login
	while IFS= read -r _prev_login; do
		[[ -n "$_prev_login" && "$_prev_login" != "$self_login" ]] && _extra_flags+=(--remove-assignee "$_prev_login")
	done < <(printf '%s' "$issue_meta_json" | jq -r '.assignees[].login' 2>/dev/null)

	set_issue_status "$issue_number" "$repo_slug" "queued" "${_extra_flags[@]}" || true
	return 0
}

#######################################
# Create per-issue worker log files with a shared fallback symlink (GH#14483).
# The primary log is namespaced by repo_slug + issue_number; the fallback is
# a plain `/tmp/pulse-{issue}.log` symlink that older validators expect.
#
# Arguments: repo_slug, issue_number
# Stdout: absolute path to the primary worker log
#######################################
_dlw_setup_worker_log() {
	local repo_slug="$1"
	local issue_number="$2"
	local safe_slug worker_log worker_log_fallback
	safe_slug=$(printf '%s' "$repo_slug" | tr '/:' '--')
	worker_log="/tmp/pulse-${safe_slug}-${issue_number}.log"
	worker_log_fallback="/tmp/pulse-${issue_number}.log"
	rm -f "$worker_log" "$worker_log_fallback"
	: >"$worker_log"
	ln -s "$worker_log" "$worker_log_fallback" 2>/dev/null || true
	printf '%s\n' "$worker_log"
	return 0
}

#######################################
# Resolve the dispatch tier from labels and select a worker model.
# Populates three module-level globals so the orchestrator can read them
# without the complexity of multi-value stdout parsing (bash 3.2 has no
# namerefs — pattern from GH#18705 decomposition memory lesson):
#   _DLW_DISPATCH_TIER        — cascade tier name: simple|standard|thinking
#   _DLW_DISPATCH_MODEL_TIER  — runtime tier: haiku|sonnet|opus
#   _DLW_SELECTED_MODEL       — concrete model name, or empty for auto-select
#
# ROUND-ROBIN MODEL SELECTION (owned by this helper, NOT the caller).
# When model_override is EMPTY, calls headless-runtime-helper.sh select
# --role worker, which resolves the worker model from the routing table /
# local override (respecting backoff DB, auth availability, provider
# allowlists, and rotation). The resolved model name is shown in the
# dispatch comment so the audit trail records exactly which provider/model
# the worker used.
#
# IMPORTANT: Callers MUST NOT pass a model override for default dispatches.
# Only pass model_override when a specific tier is required (e.g.,
# tier:thinking → opus escalation, tier:simple → haiku). Passing an
# arbitrary model here bypasses the round-robin and causes provider
# imbalance. History: GH#17503 moved model resolution here from the worker.
#
# Arguments: issue_meta_json, model_override
#######################################
_dlw_resolve_tier_and_model() {
	local issue_meta_json="$1"
	local model_override="$2"

	_DLW_DISPATCH_TIER="standard"
	_DLW_DISPATCH_MODEL_TIER="sonnet"
	local issue_labels_csv
	issue_labels_csv=$(printf '%s' "$issue_meta_json" | jq -r '[.labels[].name] | join(",")' 2>/dev/null) || issue_labels_csv=""

	# Resolve tier from labels, preferring highest rank when multiple present (t1997)
	local resolved_tier
	resolved_tier=$(_resolve_worker_tier "$issue_labels_csv")
	case "$resolved_tier" in
	tier:thinking)
		_DLW_DISPATCH_TIER="thinking"
		_DLW_DISPATCH_MODEL_TIER="opus"
		;;
	tier:standard)
		_DLW_DISPATCH_TIER="standard"
		_DLW_DISPATCH_MODEL_TIER="sonnet"
		;;
	tier:simple)
		_DLW_DISPATCH_TIER="simple"
		_DLW_DISPATCH_MODEL_TIER="haiku"
		;;
	esac

	_DLW_SELECTED_MODEL=""
	if [[ -n "$model_override" ]]; then
		_DLW_SELECTED_MODEL="$model_override"
	else
		_DLW_SELECTED_MODEL=$("$HEADLESS_RUNTIME_HELPER" select --role worker --tier "$_DLW_DISPATCH_MODEL_TIER" 2>/dev/null) || _DLW_SELECTED_MODEL=""
	fi
	return 0
}

#######################################
# Pre-create a worker worktree so the worker can start coding immediately
# instead of spending 5-8 tool calls on worktree setup. Populates two
# module-level globals:
#   _DLW_WORKTREE_PATH    — absolute path on success, empty on failure
#   _DLW_WORKTREE_BRANCH  — branch name on success, empty on failure
# Both are reset on entry so the orchestrator always sees the fresh state.
#
# The worktree is idempotent — if a previous worker already created it,
# `worktree-helper.sh add` returns the existing path. On failure, the
# worker falls back to creating its own via full-loop-helper.sh.
#
# GH#18671: worktree-helper.sh emits ANSI color codes on the "Path:" line.
# The path-extraction grep `/[^ ]*Git/[^ ]*` matches up to the next
# whitespace but ANSI reset sequences (\x1b[0m) contain no whitespace, so
# the captured path ends up with a trailing `\x1b[0m` suffix. The subsequent
# `[[ -d "$worker_worktree_path" ]]` check then fails because no such
# directory exists — the REAL path is the same string without the reset
# code. Result: pre-creation was silently marked "failed" on every dispatch,
# the worktree was successfully created but orphaned (27 leftover
# feature/auto-* directories observed in ~/Git/), the worker was launched
# without WORKER_WORKTREE_PATH, and its self-setup path crashed in ~17s
# with crash_type=no_work. That fed the t2008 stale-recovery escalation
# path, which applied needs-maintainer-review after 2 failed attempts,
# which then drained the dispatch queue to zero.
#
# Fix: strip ANSI CSI sequences before the path grep so the captured string
# is a clean filesystem path. The sed pattern matches the standard CSI form
# ESC[ ... m. The $'...' quoting evaluates \x1b (ESC, 0x1B) at parse time
# in bash.
#
# Arguments: issue_number, repo_path
#######################################
_dlw_precreate_worktree() {
	local issue_number="$1"
	local repo_path="$2"
	_DLW_WORKTREE_PATH=""
	_DLW_WORKTREE_BRANCH=""

	local _wt_helper="${SCRIPT_DIR}/worktree-helper.sh"
	if [[ ! -x "$_wt_helper" || ! -d "$repo_path" ]]; then
		return 0
	fi

	# Derive branch name from timestamp (deterministic, collision-free)
	local _branch _wt_output=""
	_branch="feature/auto-$(date +%Y%m%d-%H%M%S)"
	# Run from repo_path — worktree-helper.sh uses git commands that need
	# to be inside the repo. The pulse-wrapper's cwd is typically / (launchd).
	_wt_output=$(cd "$repo_path" && "$_wt_helper" add "$_branch" 2>&1) || true
	_wt_output=$(printf '%s' "$_wt_output" | sed $'s/\x1b\\[[0-9;]*m//g')
	local _path
	_path=$(printf '%s' "$_wt_output" | grep -oE '/[^ ]*Git/[^ ]*' | head -1) || _path=""
	if [[ -n "$_path" && -d "$_path" ]]; then
		_DLW_WORKTREE_PATH="$_path"
		_DLW_WORKTREE_BRANCH="$_branch"
		echo "[dispatch_with_dedup] Pre-created worktree for #${issue_number}: ${_DLW_WORKTREE_PATH} (branch: ${_DLW_WORKTREE_BRANCH})" >>"$LOGFILE"
	else
		# GH#18671: emit the raw extracted string on failure so future
		# regressions in path parsing are visible in the log. Previously
		# this message gave no diagnostic — 247 failures accumulated in
		# a single pulse.log before the root cause was found.
		echo "[dispatch_with_dedup] Warning: worktree pre-creation failed for #${issue_number} — worker will create its own (extracted: '${_path:-<empty>}', wt_helper stdout head: '${_wt_output:0:120}')" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# Build the worker command and launch it via `nohup` (GH#17549).
# launchd runs pulse-wrapper with StartInterval=120s. When the wrapper
# exits after its dispatch cycle, bash sends SIGHUP to background jobs.
# `nohup` makes the worker immune to SIGHUP so it survives the parent's
# exit. The EXIT trap only releases the instance lock (no child killing).
#
# Arguments:
#   $1  - issue_number
#   $2  - dispatch_title
#   $3  - issue_title
#   $4  - session_key
#   $5  - worker_log (path from _dlw_setup_worker_log)
#   $6  - prompt
#   $7  - repo_path
#   $8  - dispatch_model_tier (haiku|sonnet|opus)
#   $9  - selected_model (may be empty for auto-select)
#   $10 - worker_worktree_path (may be empty)
#   $11 - worker_worktree_branch (may be empty)
# Stdout: worker PID
#######################################
_dlw_nohup_launch() {
	local issue_number="$1"
	local dispatch_title="$2"
	local issue_title="$3"
	local session_key="$4"
	local worker_log="$5"
	local prompt="$6"
	local repo_path="$7"
	local dispatch_model_tier="$8"
	local selected_model="$9"
	local worker_worktree_path="${10}"
	local worker_worktree_branch="${11}"

	# Use issue title as session title for searchable history (not generic "Issue #NNN").
	# Workers no longer need to call session-rename — the title is set at dispatch.
	local worker_title="${issue_title:-${dispatch_title}}"

	# Launch worker — headless-runtime-helper.sh handles model selection
	# when no --model is specified. Its choose_model() uses the routing
	# table/local override, then checks backoff/auth and rotates providers.
	local -a worker_cmd=(
		env
		HEADLESS=1
		FULL_LOOP_HEADLESS=true
		WORKER_ISSUE_NUMBER="$issue_number"
	)
	# Pass worktree env vars only if pre-creation succeeded
	if [[ -n "$worker_worktree_path" ]]; then
		worker_cmd+=(
			WORKER_WORKTREE_PATH="$worker_worktree_path"
			WORKER_WORKTREE_BRANCH="$worker_worktree_branch"
		)
	fi
	worker_cmd+=(
		"$HEADLESS_RUNTIME_HELPER" run
		--role worker
		--session-key "$session_key"
		--dir "${worker_worktree_path:-$repo_path}"
		--tier "$dispatch_model_tier"
		--title "$worker_title"
		--prompt "$prompt"
	)
	if [[ -n "$selected_model" ]]; then
		worker_cmd+=(--model "$selected_model")
	fi
	nohup "${worker_cmd[@]}" </dev/null >>"$worker_log" 2>&1 &
	printf '%s\n' "$!"
	return 0
}

#######################################
# Post-launch bookkeeping: stagger delay, dispatch-ledger registration, the
# deterministic "Dispatching worker" comment on the issue, and claim-comment
# retention logging.
#
# Stagger (GH#17549): reduces SQLite write contention on opencode.db
# (busy_timeout=0). Without it, batches of 8+ workers all hit the DB
# simultaneously, causing SQLITE_BUSY → silent mid-turn death. The stagger
# gives each worker time to complete its initial DB writes before the next
# one starts.
#
# Dispatch comment (GH#15317): posted from the dispatcher, NOT from the
# worker LLM session. Previously, the worker was responsible for posting
# this comment — but workers could crash before posting, leaving no
# persistent signal. Without this signal, Layer 5 (has_dispatch_comment)
# had nothing to find, and the issue would be re-dispatched every pulse
# cycle. Evidence: awardsapp #2051 accumulated 29 DISPATCH_CLAIM comments
# over 6 hours because workers kept dying before posting.
#
# Claim comment retention (GH#17503): claim comments are NEVER deleted —
# they form the persistent audit trail and are respected as the primary
# dedup lock for 30 minutes. The deferred deletion that previously ran
# here (GH#17497) was the root cause of duplicate dispatches. Evidence:
# GH#17503 — 6 dispatches from marcusquinn + 1 from alex-solovyev,
# producing 2 duplicate PRs (#17512, #17513). This helper clears
# `_claim_comment_id` (dynamically-scoped from dispatch_with_dedup) once
# the retention message is logged so subsequent dispatches start fresh.
#
# Arguments: issue_number, repo_slug, self_login, worker_pid, session_key,
#            dispatch_tier, selected_model
#######################################
_dlw_post_launch_hooks() {
	local issue_number="$1"
	local repo_slug="$2"
	local self_login="$3"
	local worker_pid="$4"
	local session_key="$5"
	local dispatch_tier="$6"
	local selected_model="$7"

	local stagger_delay="${PULSE_DISPATCH_STAGGER_SECONDS:-8}"
	sleep "$stagger_delay"

	# Record in dispatch ledger (with tier telemetry)
	local ledger_helper="${SCRIPT_DIR}/dispatch-ledger-helper.sh"
	if [[ -x "$ledger_helper" ]]; then
		"$ledger_helper" register --session-key "$session_key" \
			--issue "$issue_number" --repo "$repo_slug" \
			--pid "$worker_pid" --tier "$dispatch_tier" \
			--model "$selected_model" 2>/dev/null || true
	fi

	local dispatch_comment_body
	local display_model="${selected_model:-auto-select (round-robin)}"
	dispatch_comment_body="<!-- ops:start — workers: skip this comment, it is audit trail not implementation context -->
Dispatching worker (deterministic).
- **Worker PID**: ${worker_pid}
- **Model**: ${display_model}
- **Tier**: ${dispatch_tier}
- **Runner**: ${self_login}
- **Issue**: #${issue_number}
<!-- ops:end -->"
	gh api "repos/${repo_slug}/issues/${issue_number}/comments" \
		--method POST --field body="$dispatch_comment_body" \
		>/dev/null 2>>"$LOGFILE" || {
		echo "[dispatch_with_dedup] Warning: failed to post deterministic dispatch comment for #${issue_number}" >>"$LOGFILE"
	}

	# _claim_comment_id is dynamically scoped from dispatch_with_dedup through
	# _dispatch_launch_worker into this helper — assignment without `local`
	# propagates up the stack, matching the pre-GH#18654 behavior.
	if [[ -n "$_claim_comment_id" ]]; then
		echo "[dispatch_with_dedup] Claim comment ${_claim_comment_id} retained for audit trail on #${issue_number} (GH#17503)" >>"$LOGFILE"
		_claim_comment_id=""
	fi
	return 0
}

#######################################
# Thin orchestrator for worker launch. Delegates each distinct concern
# (assignment + labels, log files, model resolution, issue lock, repo pull,
# worktree pre-creation, nohup launch, post-launch bookkeeping) to dedicated
# `_dlw_*` helpers. Byte-for-byte behaviourally equivalent to the
# pre-GH#18654 monolithic implementation.
#
# Arguments:
#   $1  - issue_number
#   $2  - repo_slug
#   $3  - dispatch_title
#   $4  - issue_title
#   $5  - self_login
#   $6  - repo_path
#   $7  - prompt
#   $8  - session_key
#   $9  - model_override (may be empty)
#   $10 - issue_meta_json
#######################################
_dispatch_launch_worker() {
	local issue_number="$1"
	local repo_slug="$2"
	local dispatch_title="$3"
	local issue_title="$4"
	local self_login="$5"
	local repo_path="$6"
	local prompt="$7"
	local session_key="$8"
	local model_override="$9"
	local issue_meta_json="${10}"

	_dlw_assign_and_label "$issue_number" "$repo_slug" "$self_login" "$issue_meta_json"

	local worker_log
	worker_log=$(_dlw_setup_worker_log "$repo_slug" "$issue_number")

	_dlw_resolve_tier_and_model "$issue_meta_json" "$model_override"
	local dispatch_tier="$_DLW_DISPATCH_TIER"
	local dispatch_model_tier="$_DLW_DISPATCH_MODEL_TIER"
	local selected_model="$_DLW_SELECTED_MODEL"

	# t1894/t1934: Lock issue and linked PRs during worker execution
	lock_issue_for_worker "$issue_number" "$repo_slug"

	# GH#17584: Ensure the repo is on the latest remote commit before
	# launching the worker. Without this, workers on stale checkouts
	# close issues as "Invalid — file does not exist" when the target
	# file was added in a recent commit they haven't pulled.
	if git -C "$repo_path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		git -C "$repo_path" pull --ff-only --no-rebase >>"$LOGFILE" 2>&1 || {
			echo "[dispatch_with_dedup] Warning: git pull failed for ${repo_path} — proceeding with current checkout" >>"$LOGFILE"
		}
	fi

	_dlw_precreate_worktree "$issue_number" "$repo_path"
	local worker_worktree_path="$_DLW_WORKTREE_PATH"
	local worker_worktree_branch="$_DLW_WORKTREE_BRANCH"

	local worker_pid
	worker_pid=$(_dlw_nohup_launch "$issue_number" "$dispatch_title" "$issue_title" \
		"$session_key" "$worker_log" "$prompt" "$repo_path" \
		"$dispatch_model_tier" "$selected_model" \
		"$worker_worktree_path" "$worker_worktree_branch")

	_dlw_post_launch_hooks "$issue_number" "$repo_slug" "$self_login" \
		"$worker_pid" "$session_key" "$dispatch_tier" "$selected_model"

	echo "[dispatch_with_dedup] Dispatched worker PID ${worker_pid} for #${issue_number} in ${repo_slug}" >>"$LOGFILE"
	return 0
}
