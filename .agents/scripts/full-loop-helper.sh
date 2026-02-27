#!/usr/bin/env bash
# Full Development Loop Orchestrator — state management for AI-driven dev workflow.
# Phases: task -> preflight -> pr-create -> pr-review -> postflight -> deploy
# Decision logic lives in full-loop.md; this script handles state + background exec.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

readonly SCRIPT_DIR
readonly STATE_DIR=".agents/loop-state"
readonly STATE_FILE="${STATE_DIR}/full-loop.local.state"
readonly DEFAULT_MAX_TASK_ITERATIONS=50 DEFAULT_MAX_PREFLIGHT_ITERATIONS=5 DEFAULT_MAX_PR_ITERATIONS=20
readonly BOLD='\033[1m'

HEADLESS="${FULL_LOOP_HEADLESS:-false}"

is_headless() { [[ "$HEADLESS" == "true" ]]; }

print_phase() {
	printf "\n${BOLD}${CYAN}=== Phase: %s ===${NC}\n${CYAN}%s${NC}\n\n" "$1" "$2"
}

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
no_auto_pr: ${NO_AUTO_PR:-false}
no_auto_deploy: ${NO_AUTO_DEPLOY:-false}
headless: ${HEADLESS:-false}
---

${prompt}
EOF
}

load_state() {
	[[ -f "$STATE_FILE" ]] || return 1
	# Single-pass parse of YAML frontmatter — safe variable assignment via declare
	local _key _val _line
	while IFS= read -r _line; do
		_key="${_line%%=*}"
		_val="${_line#*=}"
		# Allowlist: only set known state variables
		case "$_key" in
		PHASE | ACTIVE | ITERATION | MAX_TASK_ITERATIONS | MAX_PREFLIGHT_ITERATIONS | \
			MAX_PR_ITERATIONS | SKIP_PREFLIGHT | SKIP_POSTFLIGHT | NO_AUTO_PR | \
			NO_AUTO_DEPLOY | HEADLESS)
			printf -v "$_key" '%s' "$_val"
			;;
		esac
	done < <(awk -F': ' '/^---$/{n++;next} n==1 && NF>=2{
		gsub(/[" ]/, "", $2); k=$1; gsub(/-/, "_", k)
		print toupper(k) "=" $2
	}' "$STATE_FILE")
	CURRENT_PHASE="${PHASE:-}"
	HEADLESS="${HEADLESS:-false}"
	SAVED_PROMPT=$(sed -n '/^---$/,/^---$/d; p' "$STATE_FILE")
}

is_loop_active() { [[ -f "$STATE_FILE" ]] && grep -q '^active: true' "$STATE_FILE"; }

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

# Phase emitters — AI reads these markers and acts per full-loop.md
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

cmd_start() {
	local prompt="$1"
	shift
	local background=false
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
			background=true
			shift
			;;
		*)
			print_error "Unknown option: $1"
			return 1
			;;
		esac
	done

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

	printf "\n${BOLD}${BLUE}=== FULL DEVELOPMENT LOOP - STARTING ===${NC}\n  Task: %s\n  Branch: %s | Headless: %s\n\n" \
		"$prompt" "$(get_current_branch)" "$HEADLESS"
	[[ "${DRY_RUN:-false}" == "true" ]] && {
		print_info "Dry run - no changes made"
		return 0
	}

	save_state "task" "$prompt"
	SAVED_PROMPT="$prompt"

	if [[ "$background" == "true" ]]; then
		mkdir -p "$STATE_DIR"
		export MAX_TASK_ITERATIONS MAX_PREFLIGHT_ITERATIONS MAX_PR_ITERATIONS
		export SKIP_PREFLIGHT SKIP_POSTFLIGHT NO_AUTO_PR NO_AUTO_DEPLOY FULL_LOOP_HEADLESS="$HEADLESS"
		nohup "$0" _run_foreground "$prompt" >"${STATE_DIR}/full-loop.log" 2>&1 &
		echo "$!" >"${STATE_DIR}/full-loop.pid"
		print_success "Background loop started (PID: $!). Use 'status' or 'logs' to monitor."
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
}

show_help() {
	cat <<'EOF'
Full Development Loop Orchestrator
Usage: full-loop-helper.sh <command> [options]
Commands: start "<prompt>" | resume | status | cancel | logs [N] | help
Options: --max-task-iterations N (50) | --max-preflight-iterations N (5)
  --max-pr-iterations N (20) | --skip-preflight | --skip-postflight
  --no-auto-pr | --no-auto-deploy | --headless | --dry-run | --background
Phases: task -> preflight -> pr-create -> pr-review -> postflight -> deploy
EOF
}

main() {
	local command="${1:-help}"
	shift || true
	case "$command" in
	start) cmd_start "$@" ;; resume) cmd_resume ;; status) cmd_status ;;
	cancel) cmd_cancel ;; logs) cmd_logs "$@" ;; _run_foreground) emit_task_phase "$@" ;;
	help | --help | -h) show_help ;;
	*)
		print_error "Unknown command: $command"
		show_help
		return 1
		;;
	esac
}

main "$@"
