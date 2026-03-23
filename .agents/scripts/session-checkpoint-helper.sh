#!/usr/bin/env bash
# session-checkpoint-helper.sh - Persist session state to survive context compaction
# Part of aidevops framework: https://aidevops.sh
#
# Usage:
#   session-checkpoint-helper.sh [command] [options]
#
# Commands:
#   save              Save current session checkpoint
#   load              Load and display current checkpoint
#   continuation      Generate structured continuation prompt for new sessions
#   auto-save         Auto-detect state and save (no manual flags needed)
#   clear             Remove checkpoint file
#   status            Show checkpoint age and summary
#   help              Show this help
#
# Options:
#   --task <id>       Current task ID (e.g., t135.9)
#   --next <ids>      Comma-separated next task IDs
#   --worktree <path> Active worktree path
#   --branch <name>   Active branch name
#   --batch <name>    Batch/PR name
#   --note <text>     Free-form context note
#   --elapsed <mins>  Minutes elapsed in session
#   --target <mins>   Target session duration in minutes
#
# The checkpoint file is written to:
#   ~/.aidevops/.agent-workspace/tmp/session-checkpoint.md
#
# Design: AI agent writes checkpoint after each task completion and reads it
# before starting the next task. Survives context compaction because state
# is on disk, not in context window.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

readonly CHECKPOINT_DIR="${HOME}/.aidevops/.agent-workspace/tmp"
readonly CHECKPOINT_FILE="${CHECKPOINT_DIR}/session-checkpoint.md"

readonly BOLD='\033[1m'

# Credential patterns to redact from checkpoint content.
# Focused on secrets (API keys, tokens, passwords, connection strings).
# Does NOT include emails/IPs/home paths — those are fine in checkpoints.
# Patterns sourced from privacy-filter-helper.sh DEFAULT_PATTERNS (credential subset).
readonly -a CREDENTIAL_PATTERNS=(
	# API keys (generic)
	'sk-[a-zA-Z0-9]{20,}'
	'pk-[a-zA-Z0-9]{20,}'
	# AWS keys
	'AKIA[0-9A-Z]{16}'
	# GitHub tokens
	'gh[pousr]_[a-zA-Z0-9]{36}'
	# Bearer tokens
	'Bearer [a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+'
	# JWT tokens
	'eyJ[a-zA-Z0-9_-]*\.eyJ[a-zA-Z0-9_-]*\.[a-zA-Z0-9_-]*'
	# Stripe keys
	'sk_live_[0-9a-zA-Z]{24}'
	'pk_live_[0-9a-zA-Z]{24}'
	'sk_test_[0-9a-zA-Z]{24}'
	'pk_test_[0-9a-zA-Z]{24}'
	# Slack tokens
	'xox[baprs]-[0-9]{10,13}-[0-9]{10,13}[a-zA-Z0-9-]*'
	# SendGrid
	'SG\.[a-zA-Z0-9_-]{22}\.[a-zA-Z0-9_-]{43}'
	# Generic long hex/base64 tokens (API tokens, Cloudflare, etc.)
	'api[_-]?key["\x27[:space:]:=]+[a-zA-Z0-9_-]{16,}'
	'api[_-]?secret["\x27[:space:]:=]+[a-zA-Z0-9_-]{16,}'
	'api[_-]?token["\x27[:space:]:=]+[a-zA-Z0-9_-]{16,}'
	# Database connection strings with credentials
	'mongodb(\+srv)?://[^[:space:]]+'
	'postgres(ql)?://[^[:space:]]+'
	'mysql://[^[:space:]]+'
	'redis://[^[:space:]]+'
	# Password/secret assignments
	'password["\x27[:space:]:=]+[^[:space:]"]{8,}'
	'passwd["\x27[:space:]:=]+[^[:space:]"]{8,}'
	'secret["\x27[:space:]:=]+[^[:space:]"]{8,}'
	'token["\x27[:space:]:=]+[^[:space:]"]{8,}'
	# Private keys
	'-----BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----'
	# Gopass output (raw secret values after gopass show)
	'gopass show[^|]*\|[^[:space:]]+'
)

# Sanitize checkpoint file by redacting credential patterns.
# Runs after the checkpoint is written to disk.
# Arguments: none (operates on CHECKPOINT_FILE)
# Returns: 0 always (redaction failure is non-fatal)
sanitize_checkpoint() {
	if [[ ! -f "$CHECKPOINT_FILE" ]]; then
		return 0
	fi

	local redacted=0
	local pattern

	for pattern in "${CREDENTIAL_PATTERNS[@]}"; do
		# Check if pattern matches before attempting redaction
		if grep -qE "$pattern" "$CHECKPOINT_FILE" 2>/dev/null; then
			# Use # as sed delimiter to avoid conflicts with / in URL patterns
			sed_inplace -E "s#${pattern}#[REDACTED]#g" "$CHECKPOINT_FILE" 2>/dev/null || true
			redacted=1
		fi
	done

	if [[ "$redacted" -eq 1 ]]; then
		print_warning "Credential patterns redacted from checkpoint"
	fi

	return 0
}

ensure_dir() {
	if [[ ! -d "$CHECKPOINT_DIR" ]]; then
		mkdir -p "$CHECKPOINT_DIR"
	fi
	return 0
}

# Parse --flag value pairs for the save command.
# Sets module-scoped _save_* variables. Returns 1 on invalid args.
_parse_save_args() {
	_save_task=""
	_save_next=""
	_save_worktree=""
	_save_branch=""
	_save_batch=""
	_save_note=""
	_save_elapsed=""
	_save_target=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--task)     [[ $# -lt 2 ]] && { print_error "--task requires a value"; return 1; };     _save_task="$2";     shift 2 ;;
		--next)     [[ $# -lt 2 ]] && { print_error "--next requires a value"; return 1; };     _save_next="$2";     shift 2 ;;
		--worktree) [[ $# -lt 2 ]] && { print_error "--worktree requires a value"; return 1; }; _save_worktree="$2"; shift 2 ;;
		--branch)   [[ $# -lt 2 ]] && { print_error "--branch requires a value"; return 1; };   _save_branch="$2";   shift 2 ;;
		--batch)    [[ $# -lt 2 ]] && { print_error "--batch requires a value"; return 1; };    _save_batch="$2";    shift 2 ;;
		--note)     [[ $# -lt 2 ]] && { print_error "--note requires a value"; return 1; };     _save_note="$2";     shift 2 ;;
		--elapsed)  [[ $# -lt 2 ]] && { print_error "--elapsed requires a value"; return 1; };  _save_elapsed="$2";  shift 2 ;;
		--target)   [[ $# -lt 2 ]] && { print_error "--target requires a value"; return 1; };   _save_target="$2";   shift 2 ;;
		*) print_error "Unknown option: $1"; return 1 ;;
		esac
	done
	return 0
}

# Write the checkpoint markdown file using current _save_* variables.
# Expects _save_branch and _save_timestamp to be set by caller.
_write_checkpoint_file() {
	cat >"$CHECKPOINT_FILE" <<EOF
# Session Checkpoint

Updated: ${_save_timestamp}

## Current State

| Field | Value |
|-------|-------|
| Current Task | ${_save_task:-none} |
| Branch | ${_save_branch} |
| Worktree | ${_save_worktree:-not set} |
| Batch/PR | ${_save_batch:-not set} |
| Elapsed | ${_save_elapsed:-unknown} min |
| Target | ${_save_target:-unknown} min |

## Next Tasks

${_save_next:-No next tasks specified}

## Context Note

${_save_note:-No additional context}

## Git Status

$(git status --short 2>/dev/null || echo "Not in a git repo")

## Recent Commits (this branch)

$(git log --oneline -5 2>/dev/null || echo "No commits")

## Open Worktrees

$(git worktree list 2>/dev/null || echo "No worktrees")
EOF
	return 0
}

cmd_save() {
	_parse_save_args "$@" || return 1

	ensure_dir

	_save_timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

	# Auto-detect git state if not provided
	if [[ -z "$_save_branch" ]]; then
		_save_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")"
	fi

	_write_checkpoint_file

	# Sanitize checkpoint content — strip any credential patterns before persisting
	sanitize_checkpoint

	print_success "Checkpoint saved: ${CHECKPOINT_FILE}"
	print_info "Task: ${_save_task:-none} | Branch: ${_save_branch} | ${_save_timestamp}"
	return 0
}

cmd_load() {
	if [[ ! -f "$CHECKPOINT_FILE" ]]; then
		print_warning "No checkpoint found at ${CHECKPOINT_FILE}"
		print_info "Run: session-checkpoint-helper.sh save --task <id> --next <ids>"
		return 1
	fi

	cat "$CHECKPOINT_FILE"

	# Auto-recall relevant memories after loading checkpoint
	local memory_helper="$HOME/.aidevops/agents/scripts/memory-helper.sh"
	if [[ -x "$memory_helper" ]]; then
		echo ""
		echo "## Relevant Memories (from prior sessions)"
		echo ""

		# Recall recent memories to provide context for resumed session
		local memories
		memories=$("$memory_helper" recall --recent --limit 5 --format text 2>/dev/null || echo "")

		if [[ -n "$memories" && "$memories" != *"No memories found"* ]]; then
			echo "$memories"
		else
			echo "No recent memories found."
		fi
	fi

	return 0
}

cmd_clear() {
	if [[ -f "$CHECKPOINT_FILE" ]]; then
		rm "$CHECKPOINT_FILE"
		print_success "Checkpoint cleared"
	else
		print_info "No checkpoint to clear"
	fi
	return 0
}

cmd_status() {
	if [[ ! -f "$CHECKPOINT_FILE" ]]; then
		print_warning "No active checkpoint"
		return 1
	fi

	local file_age_seconds
	local now
	local file_mtime

	now="$(date +%s)"
	if [[ "$(uname)" == "Darwin" ]]; then
		file_mtime="$(stat -f %m "$CHECKPOINT_FILE")"
	else
		file_mtime="$(stat -c %Y "$CHECKPOINT_FILE")"
	fi
	file_age_seconds=$((now - file_mtime))

	local age_display
	if [[ $file_age_seconds -lt 60 ]]; then
		age_display="${file_age_seconds}s ago"
	elif [[ $file_age_seconds -lt 3600 ]]; then
		age_display="$((file_age_seconds / 60))m ago"
	else
		age_display="$((file_age_seconds / 3600))h $(((file_age_seconds % 3600) / 60))m ago"
	fi

	# Extract key fields
	local current_task
	current_task="$(awk -F'|' '/Current Task/ {gsub(/^[ \t]+|[ \t]+$/, "", $3); print $3; exit}' "$CHECKPOINT_FILE" || echo "unknown")"
	local branch
	branch="$(awk -F'|' '/Branch/ {gsub(/^[ \t]+|[ \t]+$/, "", $3); print $3; exit}' "$CHECKPOINT_FILE" || echo "unknown")"

	printf '%b\n' "${BOLD}Checkpoint Status${NC}"
	printf "  Age:    %s\n" "$age_display"
	printf "  Task:   %s\n" "$current_task"
	printf "  Branch: %s\n" "$branch"
	printf "  File:   %s\n" "$CHECKPOINT_FILE"

	if [[ $file_age_seconds -gt 1800 ]]; then
		print_warning "  Warning: Checkpoint is stale (>30min). Consider updating."
	fi
	return 0
}

# Gather all state needed for a continuation prompt.
# Sets module-scoped _cont_* variables for use by cmd_continuation().
_gather_continuation_state() {
	_cont_repo_root="$(git rev-parse --show-toplevel 2>/dev/null || echo "unknown")"
	_cont_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")"
	_cont_repo_name="$(basename "$_cont_repo_root")"

	# Git state
	_cont_uncommitted="$(git status --short 2>/dev/null || echo "")"
	_cont_recent_commits="$(git log --oneline -5 2>/dev/null || echo "none")"
	_cont_worktrees="$(git worktree list 2>/dev/null || echo "none")"

	# Open PRs
	_cont_open_prs="$(gh pr list --state open --json number,title,headRefName --jq '.[] | "#\(.number) [\(.headRefName)] \(.title)"' 2>/dev/null || echo "none")"

	# Supervisor batch state
	_cont_batch_state="none"
	local supervisor_helper="${SCRIPT_DIR}/supervisor-helper.sh"
	if [[ -x "$supervisor_helper" ]]; then
		_cont_batch_state="$(bash "$supervisor_helper" list --active 2>/dev/null || echo "none")"
	fi

	# TODO.md in-progress tasks
	_cont_todo_tasks="none"
	local todo_file
	for todo_file in "${_cont_repo_root}/TODO.md" "$(pwd)/TODO.md"; do
		if [[ -f "$todo_file" ]]; then
			_cont_todo_tasks="$(grep -E '^\s*- \[ \] ' "$todo_file" 2>/dev/null | head -10 || echo "none")"
			break
		fi
	done

	# Checkpoint note
	_cont_checkpoint_note="none"
	if [[ -f "$CHECKPOINT_FILE" ]]; then
		_cont_checkpoint_note="$(awk '/^## Context Note$/,/^## /' "$CHECKPOINT_FILE" | sed '1d;/^## /d' | sed '/^$/d' || echo "none")"
	fi

	# Memory recall
	_cont_recent_memories="none"
	local memory_helper="${SCRIPT_DIR}/memory-helper.sh"
	if [[ -x "$memory_helper" ]]; then
		_cont_recent_memories="$(bash "$memory_helper" recall --recent --limit 3 2>/dev/null || echo "none")"
	fi

	return 0
}

cmd_continuation() {
	# Generate a structured continuation prompt that can be fed to a new session
	# to fully reconstruct operational state.

	_gather_continuation_state

	cat <<CONTINUATION_EOF
## Session Continuation Prompt

**Generated**: $(date -u +%Y-%m-%dT%H:%M:%SZ)
**Repository**: ${_cont_repo_name} (${_cont_repo_root})
**Branch**: ${_cont_branch}

### Operational State

**Active tasks (from TODO.md)**:
${_cont_todo_tasks}

**Supervisor batch state**:
${_cont_batch_state}

**Open PRs**:
${_cont_open_prs}

### Git State

**Uncommitted changes**:
${_cont_uncommitted:-clean working tree}

**Recent commits**:
${_cont_recent_commits}

**Active worktrees**:
${_cont_worktrees}

### Context

**Last checkpoint note**:
${_cont_checkpoint_note}

**Recent memories**:
${_cont_recent_memories}

### Instructions

Resume work from the state above. Read TODO.md for the full task list.
Run \`session-checkpoint-helper.sh load\` for the last checkpoint.
Run \`pre-edit-check.sh\` before any file modifications.
CONTINUATION_EOF

	# Note: output goes to stdout for piping/capture. Status messages go to stderr.
	print_success "Continuation prompt generated" >&2
	return 0
}

cmd_auto_save() {
	# Auto-detect state and save checkpoint without requiring manual flags.
	# Designed for use in autonomous loops where the agent calls this after
	# each task completion without needing to know the exact flags.

	local current_task=""
	local next_tasks=""
	local note=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--task) [[ $# -lt 2 ]] && { print_error "--task requires a value"; return 1; }; current_task="$2"; shift 2 ;;
		--next) [[ $# -lt 2 ]] && { print_error "--next requires a value"; return 1; }; next_tasks="$2"; shift 2 ;;
		--note) [[ $# -lt 2 ]] && { print_error "--note requires a value"; return 1; }; note="$2"; shift 2 ;;
		*) print_error "Unknown option: $1"; return 1 ;;
		esac
	done

	# Auto-detect branch and worktree
	local branch
	branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")"
	local worktree
	worktree="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"

	# Auto-detect batch from supervisor if not provided
	local batch=""
	local supervisor_helper="${SCRIPT_DIR}/supervisor-helper.sh"
	if [[ -x "$supervisor_helper" ]]; then
		batch="$(bash "$supervisor_helper" list --active --format=id 2>/dev/null | head -1 || echo "")"
	fi

	# Auto-detect next tasks from TODO.md if not provided
	if [[ -z "$next_tasks" ]]; then
		local todo_file
		for todo_file in "$(pwd)/TODO.md" "${worktree}/TODO.md"; do
			if [[ -f "$todo_file" ]]; then
				next_tasks="$(grep -E '^\s*- \[ \] t[0-9]' "$todo_file" 2>/dev/null | head -3 | sed 's/.*\(t[0-9][0-9]*[^ ]*\).*/\1/' | tr '\n' ',' | sed 's/,$//' || echo "")"
				break
			fi
		done
	fi

	# Build save command args
	local -a save_args=()
	[[ -n "$current_task" ]] && save_args+=(--task "$current_task")
	[[ -n "$next_tasks" ]] && save_args+=(--next "$next_tasks")
	[[ -n "$worktree" ]] && save_args+=(--worktree "$worktree")
	[[ -n "$branch" ]] && save_args+=(--branch "$branch")
	[[ -n "$batch" ]] && save_args+=(--batch "$batch")
	[[ -n "$note" ]] && save_args+=(--note "$note")

	cmd_save "${save_args[@]}"
	return $?
}

cmd_help() {
	# Extract header comment block as help text
	sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
	return 0
}

# Main dispatch
main() {
	local command="${1:-help}"
	shift 2>/dev/null || true

	case "$command" in
	save) cmd_save "$@" ;;
	load) cmd_load ;;
	continuation) cmd_continuation ;;
	auto-save) cmd_auto_save "$@" ;;
	clear) cmd_clear ;;
	status) cmd_status ;;
	help | -h | --help) cmd_help ;;
	*)
		print_error "Unknown command: ${command}"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
