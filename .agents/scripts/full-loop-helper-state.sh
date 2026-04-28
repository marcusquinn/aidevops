#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Full-Loop State & Lifecycle -- state management, phase emission, lifecycle commands
# =============================================================================
# Sub-library for full-loop-helper.sh orchestrator. Contains state persistence
# (save/load), phase emitters, gate checks, and lifecycle commands
# (start/resume/status/cancel/logs/complete).
#
# Usage: source "${SCRIPT_DIR}/full-loop-helper-state.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, print_success, print_warning, etc.)
#   - Globals: STATE_DIR, STATE_FILE, DEFAULT_MAX_*, HEADLESS, _FG_PID_FILE
#   - Functions: is_headless, print_phase (defined in orchestrator before sourcing)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_FULL_LOOP_STATE_LIB_LOADED:-}" ]] && return 0
_FULL_LOOP_STATE_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# --- State Management ---

save_state() {
	local phase="$1" prompt="$2" pr_number="${3:-}" started_at="${4:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}"
	mkdir -p "$STATE_DIR"
	cat >"$STATE_FILE" <<EOF
---
active: true
phase: ${phase}
started_at: "${started_at}"
updated_at: "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
pr_number: "${pr_number}"
max_task_iterations: ${MAX_TASK_ITERATIONS:-$DEFAULT_MAX_TASK_ITERATIONS}
max_preflight_iterations: ${MAX_PREFLIGHT_ITERATIONS:-$DEFAULT_MAX_PREFLIGHT_ITERATIONS}
max_pr_iterations: ${MAX_PR_ITERATIONS:-$DEFAULT_MAX_PR_ITERATIONS}
skip_preflight: ${SKIP_PREFLIGHT:-false}
skip_postflight: ${SKIP_POSTFLIGHT:-false}
skip_runtime_testing: ${SKIP_RUNTIME_TESTING:-false}
no_auto_pr: ${NO_AUTO_PR:-false}
no_auto_deploy: ${NO_AUTO_DEPLOY:-false}
headless: ${HEADLESS:-false}
---

${prompt}
EOF
}

load_state() {
	[[ -f "$STATE_FILE" ]] || return 1
	# Pre-initialize all state variables with safe defaults so that set -u does
	# not abort when the state file is incomplete (missing fields are never set
	# by the awk parse loop, leaving variables unbound).
	PHASE=""
	ACTIVE=""
	ITERATION=""
	STARTED_AT="unknown"
	UPDATED_AT=""
	PR_NUMBER=""
	MAX_TASK_ITERATIONS="$DEFAULT_MAX_TASK_ITERATIONS"
	MAX_PREFLIGHT_ITERATIONS="$DEFAULT_MAX_PREFLIGHT_ITERATIONS"
	MAX_PR_ITERATIONS="$DEFAULT_MAX_PR_ITERATIONS"
	SKIP_PREFLIGHT="false"
	SKIP_POSTFLIGHT="false"
	SKIP_RUNTIME_TESTING="false"
	NO_AUTO_PR="false"
	NO_AUTO_DEPLOY="false"
	HEADLESS="${FULL_LOOP_HEADLESS:-false}"
	SAVED_PROMPT=""
	# Single-pass parse of YAML frontmatter — safe variable assignment via printf -v
	local _key _val _line
	while IFS= read -r _line; do
		_key="${_line%%=*}"
		_val="${_line#*=}"
		# Allowlist: only set known state variables
		case "$_key" in
		PHASE | ACTIVE | ITERATION | STARTED_AT | UPDATED_AT | \
			MAX_TASK_ITERATIONS | MAX_PREFLIGHT_ITERATIONS | \
			MAX_PR_ITERATIONS | SKIP_PREFLIGHT | SKIP_POSTFLIGHT | SKIP_RUNTIME_TESTING | \
			NO_AUTO_PR | NO_AUTO_DEPLOY | HEADLESS | PR_NUMBER)
			printf -v "$_key" '%s' "$_val"
			;;
		esac
	done < <(awk -F': ' '/^---$/{n++;next} n==1 && NF>=2{
		gsub(/[" ]/, "", $2); k=$1; gsub(/-/, "_", k)
		print toupper(k) "=" $2
	}' "$STATE_FILE")
	CURRENT_PHASE="${PHASE:-}"
	SAVED_PROMPT=$(sed -n '/^---$/,/^---$/d; p' "$STATE_FILE")
	return 0
}

is_loop_active() { [[ -f "$STATE_FILE" ]] && grep -q '^active: true' "$STATE_FILE"; }

# --- Utility Functions ---

is_aidevops_repo() {
	local r
	r=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
	[[ "$r" == *"/aidevops"* ]] || [[ -f "$r/.aidevops-repo" ]]
}
get_current_branch() { git branch --show-current 2>/dev/null || echo ""; }
is_on_feature_branch() {
	local b
	b=$(get_current_branch)
	[[ -n "$b" && "$b" != "main" && "$b" != "master" ]]
}

# --- Phase Emitters ---
# Drive the AI loop per full-loop.md

emit_task_phase() {
	print_phase "Task Development" "AI will iterate on task until TASK_COMPLETE"
	echo "PROMPT: $1"
	echo "When complete, emit: <promise>TASK_COMPLETE</promise>"
}
emit_preflight_phase() {
	print_phase "Preflight" "AI runs quality checks"
	[[ "${SKIP_PREFLIGHT:-false}" == "true" ]] && {
		print_warning "Preflight skipped"
		echo "<promise>PREFLIGHT_SKIPPED</promise>"
		return 0
	}
	echo "Run quality checks per full-loop.md guidance."
}
emit_pr_create_phase() {
	print_phase "PR Creation" "AI creates pull request"
	[[ "${NO_AUTO_PR:-false}" == "true" ]] && ! is_headless && {
		print_warning "Auto PR disabled"
		return 0
	}
	echo "Create PR per full-loop.md guidance."
}
emit_pr_review_phase() {
	print_phase "PR Review" "AI monitors CI and reviews"
	echo "Monitor PR per full-loop.md guidance."
}
emit_postflight_phase() {
	print_phase "Postflight" "AI verifies release health"
	[[ "${SKIP_POSTFLIGHT:-false}" == "true" ]] && {
		print_warning "Postflight skipped"
		echo "<promise>POSTFLIGHT_SKIPPED</promise>"
		return 0
	}
	echo "Verify release per full-loop.md guidance."
}
emit_deploy_phase() {
	print_phase "Deploy" "AI deploys changes"
	! is_aidevops_repo && {
		print_info "Not aidevops repo, skipping deploy"
		return 0
	}
	[[ "${NO_AUTO_DEPLOY:-false}" == "true" ]] && {
		print_warning "Auto deploy disabled"
		return 0
	}
	echo "Run setup.sh per full-loop.md guidance."
}

# --- Gate Checks ---

# Pre-start maintainer gate check (GH#17810, t2890).
# Extracts the first issue number from the prompt and verifies the linked
# issue does not have needs-maintainer-review label or missing assignee
# (GH#17810). Then inherits the pulse-side structural dispatch gates via
# dispatch-dedup-helper.sh::is-assigned so /full-loop honors parent-task
# and no-auto-dispatch blocks the same way the pulse does — closing the
# entry-point asymmetry where /full-loop bypassed gates the pulse refused
# (t2890). Mirrors the logic in .github/workflows/maintainer-gate.yml.
#
# Returns:
#   0 — gate passes (safe to start)
#   1 — gate blocked (do NOT start work)
#
# Skips gracefully when:
#   - No issue number found in prompt (not all tasks have linked issues)
#   - gh CLI unavailable or API call fails (fail-open to avoid blocking non-issue tasks)
#   - Issue is closed (already reviewed)
_check_linked_issue_gate() {
	local prompt="$1"
	local repo="${2:-}"

	# Extract first issue number from prompt — look for #NNN or issue/NNN patterns
	local issue_num
	issue_num=$(echo "$prompt" | grep -oE '#[0-9]+' | head -1 | grep -oE '[0-9]+' || true)
	if [[ -z "$issue_num" ]]; then
		# No issue number in prompt — skip gate (not all tasks reference issues)
		return 0
	fi

	# Resolve repo from git remote if not provided
	if [[ -z "$repo" ]]; then
		repo=$(git remote get-url origin 2>/dev/null | sed -E 's|.*github\.com[:/]||;s|\.git$||' || true)
	fi
	if [[ -z "$repo" ]]; then
		# Cannot determine repo — skip gate (fail-open)
		return 0
	fi

	# Fetch issue data — fail-open on API errors (don't block non-issue tasks)
	local raw_issue
	raw_issue=$(gh api "repos/${repo}/issues/${issue_num}" 2>/dev/null) || {
		print_warning "Maintainer gate pre-check: could not fetch issue #${issue_num} — skipping gate"
		return 0
	}

	local state labels assignees
	state=$(echo "$raw_issue" | jq -r '.state' 2>/dev/null || echo "unknown")
	labels=$(echo "$raw_issue" | jq -r '[.labels[]?.name] | .[]' 2>/dev/null || true)
	assignees=$(echo "$raw_issue" | jq -r '[.assignees[]?.login] | .[]' 2>/dev/null || true)

	# Skip closed issues — they've already been reviewed
	if [[ "$state" == "closed" ]]; then
		return 0
	fi

	local blocked=false reasons=""

	# Check 1: needs-maintainer-review label
	if echo "$labels" | grep -q 'needs-maintainer-review'; then
		blocked=true
		reasons="${reasons}Issue #${issue_num} has \`needs-maintainer-review\` label — a maintainer must approve before work begins.\n"
	fi

	# Check 2: no assignee (exempt quality-debt issues per GH#6623)
	if [[ -z "$assignees" ]]; then
		if echo "$labels" | grep -q 'quality-debt'; then
			: # exempt
		else
			blocked=true
			reasons="${reasons}Issue #${issue_num} has no assignee — assign the issue before starting work.\n"
		fi
	fi

	# Check 3 (t2890, t2894): inherit pulse-side structural dispatch gates by
	# calling dispatch-dedup-helper.sh::enumerate-blockers — which runs ALL
	# unconditional label checks in a single pass and emits each matching
	# signal on a separate line. Replaces the former is-assigned call + case
	# statement that short-circuited on the first match, so users now see
	# every blocker in one /full-loop invocation instead of one per retry.
	# Cost-budget, hydration window, and ownership-by-other are intentionally
	# out of scope (need nuanced interactive UX). Fail-open on missing helper
	# or empty stdout (matches the gh-api fail-open above).
	local dedup_helper="${SCRIPT_DIR}/dispatch-dedup-helper.sh"
	if [[ -x "$dedup_helper" ]]; then
		local dedup_out
		dedup_out=$("$dedup_helper" enumerate-blockers "$issue_num" "$repo" "${AIDEVOPS_SESSION_USER:-${USER:-}}" 2>/dev/null || true)
		local _blocker_line
		while IFS= read -r _blocker_line; do
			[[ -z "$_blocker_line" ]] && continue
			case "$_blocker_line" in
			*PARENT_TASK_BLOCKED*)
				blocked=true
				reasons="${reasons}Issue #${issue_num} carries the \`parent-task\` label (decomposition tracker, not a worker target). Decompose into child phase issues, or remove the label if this is no longer a parent.\n"
				;;
			*NO_AUTO_DISPATCH_BLOCKED*)
				blocked=true
				reasons="${reasons}Issue #${issue_num} carries the \`no-auto-dispatch\` label (explicit hold). Remove the label if you intentionally want worker dispatch, or work on this issue operationally (post comments, post analysis) without /full-loop.\n"
				;;
			esac
		done <<<"$dedup_out"
	fi

	if [[ "$blocked" == "true" ]]; then
		print_error "Maintainer gate pre-check BLOCKED — cannot start work:"
		printf '%b' "$reasons" >&2
		printf "To unblock:\n  1. Run: sudo aidevops approve issue %s\n  2. Assign the issue to yourself\n" "$issue_num" >&2
		return 1
	fi

	return 0
}

# Interactive claim (t2056 hardening): structurally enforce issue ownership
# when an interactive session starts a full-loop. Extracts issue number from
# the prompt and calls interactive-session-helper.sh claim, which applies
# status:in-review + self-assigns + posts a claim comment. This replaces
# prompt-only enforcement that was missed in practice (GH#18775 incident).
#
# Skips silently when:
#   - Headless mode (workers have their own dispatch claim)
#   - No issue number in prompt
#   - interactive-session-helper.sh not available
#
# Always returns 0 — claim failure is non-blocking (warn-and-continue).
_auto_claim_interactive() {
	local prompt="$1"

	# Skip in headless — workers use dispatch claims, not interactive claims
	if is_headless; then
		return 0
	fi
	# Opt-out for scripted bulk worktree operations
	if [[ -n "${AIDEVOPS_SKIP_AUTO_CLAIM:-}" ]]; then
		return 0
	fi

	# Extract issue number (same pattern as _check_linked_issue_gate)
	local issue_num
	issue_num=$(echo "$prompt" | grep -oE '#[0-9]+' | head -1 | grep -oE '[0-9]+' || true)
	if [[ -z "$issue_num" ]]; then
		return 0
	fi

	# Resolve repo slug
	local repo
	repo=$(git remote get-url origin 2>/dev/null | sed -E 's|.*github\.com[:/]||;s|\.git$||' || true)
	if [[ -z "$repo" ]]; then
		return 0
	fi

	# Call the interactive claim helper — it handles offline, idempotency,
	# self-assign, status label, stamp, and claim comment internally.
	local helper="${SCRIPT_DIR}/interactive-session-helper.sh"
	if [[ -x "$helper" ]]; then
		"$helper" claim "$issue_num" "$repo" --worktree "$(pwd)" || true
		print_info "Interactive claim: #${issue_num} in ${repo} — pulse dispatch blocked"
	else
		print_warning "interactive-session-helper.sh not found — skipping interactive claim"
	fi
	return 0
}

# --- Start/Resume Infrastructure ---

# Initialize option variables with defaults so set -u doesn't crash on
# export when flags are not passed.
_init_start_defaults() {
	MAX_TASK_ITERATIONS="${MAX_TASK_ITERATIONS:-$DEFAULT_MAX_TASK_ITERATIONS}"
	MAX_PREFLIGHT_ITERATIONS="${MAX_PREFLIGHT_ITERATIONS:-$DEFAULT_MAX_PREFLIGHT_ITERATIONS}"
	MAX_PR_ITERATIONS="${MAX_PR_ITERATIONS:-$DEFAULT_MAX_PR_ITERATIONS}"
	SKIP_PREFLIGHT="${SKIP_PREFLIGHT:-false}"
	SKIP_POSTFLIGHT="${SKIP_POSTFLIGHT:-false}"
	SKIP_RUNTIME_TESTING="${SKIP_RUNTIME_TESTING:-false}"
	NO_AUTO_PR="${NO_AUTO_PR:-false}"
	NO_AUTO_DEPLOY="${NO_AUTO_DEPLOY:-false}"
	DRY_RUN="${DRY_RUN:-false}"
	_BACKGROUND=false
	return 0
}

# Parse start subcommand options. Sets global option variables and _BACKGROUND.
# Arguments: all remaining args after the prompt string.
# Returns: 0 on success, 1 on unknown option.
_parse_start_options() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--max-task-iterations)
			MAX_TASK_ITERATIONS="$2"
			shift 2
			;;
		--max-preflight-iterations)
			MAX_PREFLIGHT_ITERATIONS="$2"
			shift 2
			;;
		--max-pr-iterations)
			MAX_PR_ITERATIONS="$2"
			shift 2
			;;
		--skip-preflight)
			SKIP_PREFLIGHT=true
			shift
			;;
		--skip-postflight)
			SKIP_POSTFLIGHT=true
			shift
			;;
		--skip-runtime-testing)
			SKIP_RUNTIME_TESTING=true
			shift
			;;
		--no-auto-pr)
			NO_AUTO_PR=true
			shift
			;;
		--no-auto-deploy)
			NO_AUTO_DEPLOY=true
			shift
			;;
		--headless)
			HEADLESS=true
			shift
			;;
		--dry-run)
			DRY_RUN=true
			shift
			;;
		--background | --bg)
			_BACKGROUND=true
			shift
			;;
		*)
			print_error "Unknown option: $1"
			return 1
			;;
		esac
	done
	return 0
}

# Launch the loop in the background via nohup.
# Arguments: $1 — prompt string.
_launch_background() {
	local prompt="$1"
	mkdir -p "$STATE_DIR"
	export MAX_TASK_ITERATIONS MAX_PREFLIGHT_ITERATIONS MAX_PR_ITERATIONS
	export SKIP_PREFLIGHT SKIP_POSTFLIGHT SKIP_RUNTIME_TESTING NO_AUTO_PR NO_AUTO_DEPLOY FULL_LOOP_HEADLESS="$HEADLESS"
	nohup "$0" _run_foreground "$prompt" >"${STATE_DIR}/full-loop.log" 2>&1 &
	echo "$!" >"${STATE_DIR}/full-loop.pid"
	print_success "Background loop started (PID: $!). Use 'status' or 'logs' to monitor."
	return 0
}

# --- Lifecycle Commands ---

cmd_start() {
	local prompt="$1"
	shift

	_init_start_defaults
	_parse_start_options "$@" || return 1

	[[ -z "$prompt" ]] && {
		print_error "Usage: full-loop-helper.sh start \"<prompt>\" [options]"
		return 1
	}
	is_loop_active && {
		print_warning "Loop already active. Use 'resume' or 'cancel'."
		return 1
	}
	is_on_feature_branch || {
		print_error "Must be on a feature branch"
		return 1
	}

	# Pre-start maintainer gate check (GH#17810): block if linked issue has
	# needs-maintainer-review label or no assignee. Mirrors the CI gate in
	# .github/workflows/maintainer-gate.yml so workers fail fast locally
	# instead of creating PRs that will always fail CI.
	_check_linked_issue_gate "$prompt" || return 1

	# Interactive claim (t2056 hardening): when not headless, automatically
	# claim the linked issue so the pulse cannot dispatch a parallel worker
	# during the window between start and PR creation. This closes the race
	# that prompt-only enforcement missed (GH#18775 incident).
	_auto_claim_interactive "$prompt"

	printf "\n${BOLD}${BLUE}=== FULL DEVELOPMENT LOOP - STARTING ===${NC}\n  Task: %s\n  Branch: %s | Headless: %s\n\n" \
		"$prompt" "$(get_current_branch)" "$HEADLESS"
	[[ "${DRY_RUN:-false}" == "true" ]] && {
		print_info "Dry run - no changes made"
		return 0
	}

	save_state "task" "$prompt"
	SAVED_PROMPT="$prompt"

	if [[ "$_BACKGROUND" == "true" ]]; then
		_launch_background "$prompt"
		return 0
	fi
	emit_task_phase "$prompt"
}

# Phase transition map: current -> next phase + emit function
_next_phase() {
	case "$1" in
	task) echo "preflight emit_preflight_phase" ;;
	preflight) echo "pr-create emit_pr_create_phase" ;;
	pr-create) echo "pr-review emit_pr_review_phase" ;;
	pr-review) echo "postflight emit_postflight_phase" ;;
	postflight) echo "deploy emit_deploy_phase" ;;
	deploy) echo "complete cmd_complete" ;;
	complete) echo "complete cmd_complete" ;;
	*) return 1 ;;
	esac
}

cmd_resume() {
	is_loop_active || {
		print_error "No active loop to resume"
		return 1
	}
	load_state
	print_info "Resuming from phase: $CURRENT_PHASE"
	local transition
	transition=$(_next_phase "$CURRENT_PHASE") || {
		print_error "Unknown phase: $CURRENT_PHASE"
		return 1
	}
	local next_phase="${transition%% *}" emit_fn="${transition#* }"
	save_state "$next_phase" "$SAVED_PROMPT" "${PR_NUMBER:-}" "$STARTED_AT"
	$emit_fn
}

cmd_status() {
	is_loop_active || {
		echo "No active full loop"
		return 0
	}
	load_state
	printf "\n${BOLD}Full Loop Status${NC}\nPhase: ${CYAN}%s${NC} | Started: %s | PR: %s | Headless: %s\nPrompt: %s\n\n" \
		"$CURRENT_PHASE" "$STARTED_AT" "${PR_NUMBER:-none}" "$HEADLESS" "$(echo "$SAVED_PROMPT" | head -3)"
}

cmd_cancel() {
	is_loop_active || {
		print_warning "No active loop to cancel"
		return 0
	}
	local pid_file="${STATE_DIR}/full-loop.pid"
	if [[ -f "$pid_file" ]]; then
		local pid
		pid=$(cat "$pid_file")
		kill -0 "$pid" 2>/dev/null && {
			kill "$pid" 2>/dev/null || true
			sleep 1
			kill -9 "$pid" 2>/dev/null || true
		}
		rm -f "$pid_file"
	fi
	rm -f "$STATE_FILE" ".agents/loop-state/ralph-loop.local.state" ".agents/loop-state/quality-loop.local.state" 2>/dev/null
	print_success "Full loop cancelled"
}

cmd_logs() {
	local log_file="${STATE_DIR}/full-loop.log" lines="${1:-50}"
	[[ -f "$log_file" ]] || {
		print_warning "No log file. Start with --background first."
		return 1
	}
	local pid_file="${STATE_DIR}/full-loop.pid"
	if [[ -f "$pid_file" ]]; then
		local pid
		pid=$(cat "$pid_file")
		kill -0 "$pid" 2>/dev/null && print_info "Running (PID: $pid)" || print_warning "Not running (was PID: $pid)"
	fi
	printf "\n${BOLD}Full Loop Logs (last %d lines)${NC}\n" "$lines"
	tail -n "$lines" "$log_file"
}

cmd_complete() {
	load_state 2>/dev/null || true
	printf "\n${BOLD}${GREEN}=== FULL DEVELOPMENT LOOP - COMPLETE ===${NC}\n"
	printf "Task: done | Preflight: passed | PR: #%s | Postflight: healthy" "${PR_NUMBER:-unknown}"
	is_aidevops_repo && printf " | Deploy: done"
	printf "\n\n"
	rm -f "$STATE_FILE"
	echo "<promise>FULL_LOOP_COMPLETE</promise>"
} # nice — entire dev lifecycle in one pass
