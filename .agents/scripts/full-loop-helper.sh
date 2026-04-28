#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Full Development Loop Orchestrator -- state management for AI-driven dev workflow.
# =============================================================================
# Phases: task -> preflight -> pr-create -> pr-review -> postflight -> deploy
# Decision logic lives in full-loop.md; this script handles state + background exec.
#
# Sub-libraries (sourced below):
#   full-loop-helper-state.sh   -- state persistence, phase emitters, lifecycle commands
#   full-loop-helper-commit.sh  -- staging, validators, PR creation, merge summary
#   full-loop-helper-merge.sh   -- merge execution, admin fallback, resource unlocking

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"
source "${SCRIPT_DIR}/shared-claim-lifecycle.sh"

readonly SCRIPT_DIR
readonly STATE_DIR=".agents/loop-state"
readonly STATE_FILE="${STATE_DIR}/full-loop.local.state"
readonly DEFAULT_MAX_TASK_ITERATIONS=50 DEFAULT_MAX_PREFLIGHT_ITERATIONS=5 DEFAULT_MAX_PR_ITERATIONS=20
[[ -z "${BOLD+x}" ]] && BOLD='\033[1m'

HEADLESS="${FULL_LOOP_HEADLESS:-false}"
_FG_PID_FILE=""

is_headless() { [[ "$HEADLESS" == "true" ]]; }

print_phase() {
	printf "\n${BOLD}${CYAN}=== Phase: %s ===${NC}\n${CYAN}%s${NC}\n\n" "$1" "$2"
}

# --- Source sub-libraries ---

# shellcheck source=./full-loop-helper-state.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/full-loop-helper-state.sh"

# shellcheck source=./full-loop-helper-commit.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/full-loop-helper-commit.sh"

# shellcheck source=./full-loop-helper-merge.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/full-loop-helper-merge.sh"

# --- cmd_commit_and_pr ---
# Kept in the orchestrator because the function body exceeds 100 lines,
# triggering the function-complexity gate. Moving it to a sub-library would
# create a new (file, fname) identity-key violation. See reference/large-file-split.md §3.
#
# Commit-and-PR: stage, commit, rebase, push, create PR, post merge summary.
# Collapses full-loop steps 4.1-4.2.1 into a single deterministic call.
# Workers and interactive sessions both use this — no parallel logic.
#
# Usage: full-loop-helper.sh commit-and-pr --issue <N> --message <msg> [--title <title>] [--summary <what>] [--testing <how>] [--decisions <notes>] [--label <label>...] [--allow-parent-close] [--skip-hooks]
# Exit codes: 0 = PR created (prints PR number to stdout), 1 = failure
# --allow-parent-close: skip the parent-task keyword guard (final-phase PR only)
# --skip-hooks: pass --no-verify to git push (bypasses pre-push hooks). Use for doc-only PRs
#   after manually verifying no secrets/private-slugs in the diff. See GH#20138.
#
# On rebase conflict: returns 1 with instructions. Caller must resolve and retry.
# On push failure: returns 1. Caller should check remote state.
# On PR creation failure: returns 1. Changes are committed and pushed — caller
# can create the PR manually.
cmd_commit_and_pr() {
	local issue_number="" commit_message="" pr_title="" summary_what="" summary_testing="" summary_decisions=""
	local -a extra_labels=()
	local allow_parent_close=0
	local skip_hooks=0

	_parse_commit_and_pr_args "$@" || return 1

	# Validate inputs and detect repo/branch (sets $repo and $branch in this scope)
	local repo="" branch=""
	_validate_commit_and_pr_inputs "$issue_number" "$commit_message" || return 1

	_stage_and_commit "$commit_message" || return 1
	# t2842: project-aware validators (auto-fix format/lint, fail-closed typecheck).
	# Inserted between commit and push so amends apply to the same commit
	# the worker just made, and so failures abort BEFORE we push broken code.
	_run_project_validators "$skip_hooks" || return 1
	_rebase_and_push "$branch" "$skip_hooks" || return 1

	# Build PR metadata (t2720: prefer tNNN from TODO.md so issue-sync's
	# PR-merge auto-completion regex can extract a task_id and flip [ ] → [x]).
	# t2825/RC3: use _compose_pr_title so a commit_message that already begins
	# with tNNN: or GH#NNN: is not double-prefixed (canonical failure: PR #20817).
	if [[ -z "$pr_title" ]]; then
		pr_title="$(_compose_pr_title "$issue_number" "$commit_message")"
	fi

	local origin_label="origin:interactive"
	if [[ "${HEADLESS:-}" == "1" || "${FULL_LOOP_HEADLESS:-}" == "true" ]]; then
		origin_label="origin:worker"
	fi

	local sig_footer=""
	local sig_helper="${SCRIPT_DIR}/gh-signature-helper.sh"
	if [[ -x "$sig_helper" ]]; then
		sig_footer=$("$sig_helper" footer 2>/dev/null || echo "")
	fi

	local files_changed=""
	files_changed=$(git diff --name-only origin/main..HEAD 2>/dev/null | tr '\n' ', ' | sed 's/,$//' || echo "")

	# t2242: Determine closing keyword — auto-swap Resolves to For when linked
	# issue has parent-task label, unless --allow-parent-close overrides.
	local closing_keyword="Resolves"
	if [[ "$allow_parent_close" -eq 1 ]]; then
		closing_keyword="Resolves"
	elif _issue_has_parent_task_label "$issue_number" "$repo"; then
		closing_keyword="For"
		print_info "Issue #${issue_number} has parent-task label — using 'For' keyword (t2242)"
	fi

	local pr_body=""
	pr_body=$(_build_pr_body "$issue_number" "$summary_what" "$summary_testing" "$files_changed" "$sig_footer" "$closing_keyword")

	# t2046: parent-task keyword guard — prevent Resolves/Closes/Fixes on
	# parent-task issues. The parent must stay open until all phase children merge.
	# Runs in --strict mode (exit 2 = abort PR creation). Pass --allow-parent-close
	# for the legitimate final-phase PR that intentionally closes the parent tracker.
	local keyword_guard="${SCRIPT_DIR}/parent-task-keyword-guard.sh"
	if [[ -x "$keyword_guard" ]]; then
		local tmp_pr_body
		tmp_pr_body=$(mktemp)
		printf '%s\n' "$pr_body" >"$tmp_pr_body"
		local guard_args=("check-body" "--body-file" "$tmp_pr_body" "--repo" "$repo" "--strict")
		[[ "$allow_parent_close" -eq 1 ]] && guard_args+=("--allow-parent-close")
		local guard_rc=0
		"$keyword_guard" "${guard_args[@]}" 2>&1 >&2 || guard_rc=$?
		rm -f "$tmp_pr_body"
		if [[ "$guard_rc" -eq 2 ]]; then
			print_error "Aborting PR creation: parent-task keyword violation (t2046). See error above."
			return 1
		fi
	fi

	# t1955: Validate dispatch claim before creating PR. In headless mode,
	# abort if this worker was stale-recovered and replaced by another runner.
	_validate_worker_claim "$issue_number" "$repo" || {
		print_error "Aborting: dispatch claim no longer valid for #${issue_number} (t1955)"
		return 1
	}

	# t2091: Guard against filing PRs on already-closed issues.
	# A worker racing an interactive session may finish implementation after
	# the issue was already resolved. Opening a PR against a closed issue
	# creates noise, wastes review time, and can trigger duplicate closures.
	# Applies to all modes (interactive and headless).
	local _pre_pr_issue_state=""
	_pre_pr_issue_state=$(gh issue view "$issue_number" --repo "$repo" \
		--json state -q '.state' 2>/dev/null || echo "")
	if [[ "$_pre_pr_issue_state" == "CLOSED" ]]; then
		print_error "Aborting: issue #${issue_number} is already closed — not opening a duplicate PR (t2091)"
		gh_issue_comment "$issue_number" --repo "$repo" \
			--body "<!-- ops:start — workers: skip this comment, it is audit trail not implementation context -->
Worker aborted PR creation: issue #${issue_number} was already closed by the time this session completed implementation. No PR was opened.
<!-- ops:end -->" \
			2>/dev/null || true
		return 1
	fi

	local pr_number=""
	pr_number=$(_create_pr "$repo" "$pr_title" "$pr_body" "$origin_label" "${extra_labels[@]+"${extra_labels[@]}"}") || return 1

	_post_merge_summary "$pr_number" "$repo" "$issue_number" "$summary_what" "$files_changed" "$summary_testing" "$summary_decisions"
	_label_issue_in_review "$issue_number" "$repo"

	# Output PR number for caller to pass to `merge`
	printf '%s\n' "$pr_number"
	return 0
}

# --- Help & Main ---

show_help() {
	cat <<'EOF'
Full Development Loop Orchestrator
Usage: full-loop-helper.sh <command> [options]
Commands:
  start "<prompt>"              Start a new development loop
  resume                        Resume from last phase
  status                        Show current loop state
  cancel                        Cancel active loop
  logs [N]                      Show last N log lines (default: 50)
  commit-and-pr --issue N --message "msg"  Stage, commit, rebase, push, create PR, post merge summary
                [--skip-hooks]             Pass --no-verify to git push (doc-only PRs, GH#20138)
  pre-merge-gate <PR> [REPO]    Check review bot gate before merge (GH#17541)
  merge <PR> [REPO] [--squash|--merge|--rebase] [--admin] [--auto]
                                Gate-enforced merge (runs pre-merge-gate first).
                                --admin / --auto pass through to gh pr merge
                                for branch-protected personal-account repos (GH#18731).
                                --admin and --auto are mutually exclusive at the
                                gh CLI level; if both are given, --admin wins and
                                --auto is dropped (GH#19310).
  help                          Show this help
Options: --max-task-iterations N (50) | --max-preflight-iterations N (5)
  --max-pr-iterations N (20) | --skip-preflight | --skip-postflight
  --skip-runtime-testing | --no-auto-pr | --no-auto-deploy
  --headless | --dry-run | --background
Phases: task -> preflight -> pr-create -> pr-review -> postflight -> deploy
EOF
}

_run_foreground() {
	local prompt="$1"
	# Use a global for the trap — local variables are out of scope when the
	# EXIT trap fires after the function returns (causes unbound variable
	# crash under set -u).
	_FG_PID_FILE="${STATE_DIR}/full-loop.pid"
	trap 'rm -f "$_FG_PID_FILE"' EXIT
	emit_task_phase "$prompt"
	return 0
}

main() {
	local command="${1:-help}"
	shift || true
	case "$command" in
	start) cmd_start "$@" ;; resume) cmd_resume ;; status) cmd_status ;;
	cancel) cmd_cancel ;; logs) cmd_logs "$@" ;; _run_foreground) _run_foreground "$@" ;;
	commit-and-pr) cmd_commit_and_pr "$@" ;;
	pre-merge-gate) cmd_pre_merge_gate "$@" ;;
	merge) cmd_merge "$@" ;;
	help | --help | -h) show_help ;;
	*)
		print_error "Unknown command: $command"
		show_help
		return 1
		;;
	esac
}

main "$@"
