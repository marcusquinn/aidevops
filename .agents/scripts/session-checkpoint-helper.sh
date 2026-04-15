#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
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

[[ -z "${BOLD+x}" ]] && BOLD='\033[1m'

# Credential patterns to redact from checkpoint content.
# Focused on secrets (API keys, tokens, passwords, connection strings).
# Does NOT include emails/IPs/home paths — those are fine in checkpoints.
# Patterns sourced from privacy-filter-helper.sh DEFAULT_PATTERNS (credential subset).
#
# Note on false positives: sk-/pk- prefixes with 20+ alphanumeric chars may match
# non-secret identifiers (e.g., CSS classes like "sk-navigation-section-main-content").
# The 20-char minimum reduces this, but security-first: false redaction is acceptable.
# To tighten later, consider word-boundary anchors (\b) or entropy checks.

# Shared suffix for key=value assignment patterns (password, secret, token, etc.)
# Matches: separator (quotes, whitespace, colon, equals) + 8+ non-space chars
readonly _ASSIGN_SUFFIX='["'"'"'[:space:]:=]+[^[:space:]"]{8,}'

readonly -a CREDENTIAL_PATTERNS=(
	# API keys (generic) — see false-positive note above re: sk-/pk- prefixes
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
	# Note: use shell quote-concatenation instead of \x27 for single-quote matching (POSIX-portable)
	'api[_-]?key["'"'"'[:space:]:=]+[a-zA-Z0-9_-]{16,}'
	'api[_-]?secret["'"'"'[:space:]:=]+[a-zA-Z0-9_-]{16,}'
	'api[_-]?token["'"'"'[:space:]:=]+[a-zA-Z0-9_-]{16,}'
	# Database connection strings with credentials
	'mongodb(\+srv)?://[^[:space:]]+'
	'postgres(ql)?://[^[:space:]]+'
	'mysql://[^[:space:]]+'
	'redis://[^[:space:]]+'
	# Password/secret assignments (suffix extracted to _ASSIGN_SUFFIX)
	"password${_ASSIGN_SUFFIX}"
	"passwd${_ASSIGN_SUFFIX}"
	"secret${_ASSIGN_SUFFIX}"
	"token${_ASSIGN_SUFFIX}"
	# Private keys
	'-----BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----'
	# Gopass command invocations — redacts the command itself (e.g., "gopass show path/to/secret").
	# Limitation: gopass outputs the secret value on a *separate line* after the command.
	# That subsequent line is not caught here; it relies on the password/token/key patterns
	# above to match the value. Avoid pasting raw gopass output into checkpoint notes.
	'gopass show [a-zA-Z0-9/_.-]+'
)

# Sanitize a file by redacting credential patterns.
# Uses perl for regex substitution to avoid sed delimiter conflicts —
# CREDENTIAL_PATTERNS contain metacharacters and URL slashes that conflict
# with any fixed sed delimiter (/, #, etc.).
# Arguments:
#   $1 - file path to sanitize (defaults to CHECKPOINT_FILE)
# Returns: 0 always (redaction failure is non-fatal)
sanitize_checkpoint() {
	local target_file="${1:-$CHECKPOINT_FILE}"

	if [[ ! -f "$target_file" ]]; then
		return 0
	fi

	local redacted=0
	local pattern
	local grep_rc

	for pattern in "${CREDENTIAL_PATTERNS[@]}"; do
		# Check if pattern matches before attempting redaction.
		# Capture exit code once to avoid running grep twice in debug mode:
		# 0 = match, 1 = no match, 2 = regex/file error.
		grep_rc=0
		grep -qE "$pattern" "$target_file" 2>/dev/null || grep_rc=$?

		if [[ "$grep_rc" -eq 0 ]]; then
			# Use perl -pi for in-place regex substitution — avoids delimiter
			# conflicts that sed has with patterns containing / # or other chars.
			# The {} delimiters in s{}{} are safe since no patterns use braces
			# as literal characters (they're always regex quantifiers).
			if perl -pi -e "s{$pattern}{[REDACTED]}g" "$target_file" 2>/dev/null; then
				redacted=1
			else
				[[ -n "${DEBUG:-}" ]] && print_warning "Failed to redact pattern: ${pattern:0:30}..."
			fi
		elif [[ -n "${DEBUG:-}" && "$grep_rc" -eq 2 ]]; then
			# Distinguish "no match" (exit 1) from "regex error" (exit 2)
			# to surface malformed patterns in debug mode
			print_warning "Regex error in pattern: ${pattern:0:30}..."
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
		--task)
			[[ $# -lt 2 ]] && {
				print_error "--task requires a value"
				return 1
			}
			_save_task="$2"
			shift 2
			;;
		--next)
			[[ $# -lt 2 ]] && {
				print_error "--next requires a value"
				return 1
			}
			_save_next="$2"
			shift 2
			;;
		--worktree)
			[[ $# -lt 2 ]] && {
				print_error "--worktree requires a value"
				return 1
			}
			_save_worktree="$2"
			shift 2
			;;
		--branch)
			[[ $# -lt 2 ]] && {
				print_error "--branch requires a value"
				return 1
			}
			_save_branch="$2"
			shift 2
			;;
		--batch)
			[[ $# -lt 2 ]] && {
				print_error "--batch requires a value"
				return 1
			}
			_save_batch="$2"
			shift 2
			;;
		--note)
			[[ $# -lt 2 ]] && {
				print_error "--note requires a value"
				return 1
			}
			_save_note="$2"
			shift 2
			;;
		--elapsed)
			[[ $# -lt 2 ]] && {
				print_error "--elapsed requires a value"
				return 1
			}
			_save_elapsed="$2"
			shift 2
			;;
		--target)
			[[ $# -lt 2 ]] && {
				print_error "--target requires a value"
				return 1
			}
			_save_target="$2"
			shift 2
			;;
		*)
			print_error "Unknown option: $1"
			return 1
			;;
		esac
	done
	return 0
}

# Write the checkpoint markdown file using current _save_* variables.
# Expects _save_branch and _save_timestamp to be set by caller.
# Arguments:
#   $1 - output file path (defaults to CHECKPOINT_FILE)
_write_checkpoint_file() {
	local output_file="${1:-$CHECKPOINT_FILE}"
	cat >"$output_file" <<EOF
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

	# Atomic write: write to temp file, sanitize, then mv to final location.
	# This avoids a window where credentials exist unredacted on disk —
	# if the script is interrupted between write and sanitize, the temp file
	# is cleaned up (or left orphaned in tmp/) rather than persisting as the
	# checkpoint with raw credentials.
	local temp_file
	temp_file="$(mktemp "${CHECKPOINT_DIR}/checkpoint.XXXXXX")" || {
		print_error "Failed to create temp file for checkpoint"
		return 1
	}

	# Write checkpoint to temp file, sanitize it, then atomically move
	_write_checkpoint_file "$temp_file"
	sanitize_checkpoint "$temp_file"
	if ! mv "$temp_file" "$CHECKPOINT_FILE"; then
		rm -f "$temp_file"
		print_error "Failed to write checkpoint to ${CHECKPOINT_FILE}"
		return 1
	fi

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
	local memory_helper="${SCRIPT_DIR}/memory-helper.sh"
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
	local supervisor_helper="${SCRIPT_DIR}/pulse-wrapper.sh"
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

	# Write to temp file so we can sanitize before outputting — continuation
	# state may include PR titles, TODO content, or memory recall that
	# inadvertently contains credential material.
	local temp_file
	temp_file="$(mktemp "${CHECKPOINT_DIR}/continuation.XXXXXX")" || {
		print_error "Failed to create temp file for continuation" >&2
		return 1
	}

	cat >"$temp_file" <<CONTINUATION_EOF
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

	# Sanitize before outputting to stdout
	sanitize_checkpoint "$temp_file"
	cat "$temp_file"
	rm -f "$temp_file"

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
		--task)
			[[ $# -lt 2 ]] && {
				print_error "--task requires a value"
				return 1
			}
			current_task="$2"
			shift 2
			;;
		--next)
			[[ $# -lt 2 ]] && {
				print_error "--next requires a value"
				return 1
			}
			next_tasks="$2"
			shift 2
			;;
		--note)
			[[ $# -lt 2 ]] && {
				print_error "--note requires a value"
				return 1
			}
			note="$2"
			shift 2
			;;
		*)
			print_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	# Auto-detect branch and worktree
	local branch
	branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")"
	local worktree
	worktree="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"

	# Auto-detect batch from supervisor if not provided
	local batch=""
	local supervisor_helper="${SCRIPT_DIR}/pulse-wrapper.sh"
	if [[ -x "$supervisor_helper" ]]; then
		batch="$(bash "$supervisor_helper" list --active --format=id 2>/dev/null | head -1 || echo "")"
	fi

	# Auto-detect next tasks from TODO.md if not provided
	if [[ -z "$next_tasks" ]]; then
		local todo_file
		for todo_file in "$(pwd)/TODO.md" "${worktree}/TODO.md"; do
			[[ -f "$todo_file" ]] || continue
			next_tasks="$(grep -E '^\s*- \[ \] t[0-9]' "$todo_file" 2>/dev/null | head -3 | sed 's/.*\(t[0-9][0-9]*[^ ]*\).*/\1/' | tr '\n' ',' | sed 's/,$//' || echo "")"
			break
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
