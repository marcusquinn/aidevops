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
#   recovery-save     Save a structured safety-stop recovery checkpoint
#   recovery-resolve  Resolve the current recovery checkpoint with evidence
#   recovery-status   Print recovery state (use --json for machine output)
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
# Checkpoints are repo-scoped and written to:
#   ~/.aidevops/.agent-workspace/tmp/session-checkpoints/repo-<hash>.md
# Legacy singleton checkpoints at tmp/session-checkpoint.md are ignored by
# load/continuation paths so one repository cannot replay another repository's
# operational state during compaction.
#
# Design: AI agent writes checkpoint after each task completion and reads it
# before starting the next task. Survives context compaction because state
# is on disk, not in context window.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

readonly CHECKPOINT_DIR="${HOME}/.aidevops/.agent-workspace/tmp"
readonly CHECKPOINT_SCOPED_DIR="${CHECKPOINT_DIR}/session-checkpoints"
readonly LEGACY_CHECKPOINT_FILE="${CHECKPOINT_DIR}/session-checkpoint.md"
readonly OUTPUT_FORMAT_JSON="json"

[[ -z "${BOLD+x}" ]] && BOLD='\033[1m'

# Credential patterns to redact from checkpoint content.
# Focused on secrets (API keys, tokens, passwords, connection strings).
# Does NOT include emails/IPs/home paths; repo-scoped checkpoint isolation is
# the privacy boundary that prevents cross-project replay of those details.
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
#   $1 - file path to sanitize (defaults to current repo-scoped checkpoint)
# Returns: 0 always (redaction failure is non-fatal)
sanitize_checkpoint() {
	local default_file=""
	default_file="$(checkpoint_file_for_current_scope)"
	local target_file="${1:-$default_file}"

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
	if [[ ! -d "$CHECKPOINT_SCOPED_DIR" ]]; then
		mkdir -p "$CHECKPOINT_SCOPED_DIR"
	fi
	return 0
}

# Resolve the repository scope used for checkpoint isolation.
# Returns the git root when available, otherwise the physical current directory.
checkpoint_scope_root() {
	local root=""
	root="$(git rev-parse --show-toplevel 2>/dev/null || pwd -P 2>/dev/null || printf '%s' "$PWD")"
	printf '%s\n' "$root"
	return 0
}

# Derive a stable, non-disclosing filename key from a repository scope.
checkpoint_scope_key() {
	local scope_root="$1"
	local digest=""
	digest="$(printf '%s' "$scope_root" | shasum -a 256 | cut -d ' ' -f 1)"
	printf '%s\n' "${digest:0:16}"
	return 0
}

# Return the checkpoint file for the current repository scope.
checkpoint_file_for_current_scope() {
	local scope_root=""
	local scope_key=""
	scope_root="$(checkpoint_scope_root)"
	scope_key="$(checkpoint_scope_key "$scope_root")"
	printf '%s/repo-%s.md\n' "$CHECKPOINT_SCOPED_DIR" "$scope_key"
	return 0
}

# Return a single-line git branch label without leaking stderr from unborn repos.
current_branch_label() {
	local branch=""
	branch="$(git branch --show-current 2>/dev/null || true)"
	if [[ -z "$branch" ]]; then
		branch="$(git symbolic-ref --short HEAD 2>/dev/null || true)"
	fi
	if [[ -z "$branch" ]]; then
		branch="unknown"
	fi
	printf '%s\n' "$branch"
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
	_save_recovery_session=""
	_save_recovery_objective=""
	_save_recovery_directions=""
	_save_recovery_trigger=""
	_save_recovery_completed=""
	_save_recovery_remaining=""
	_save_recovery_unsafe_route=""
	_save_recovery_next_route=""
	_save_recovery_resume_condition=""
	_save_recovery_owner=""
	_save_recovery_status=""
	_save_recovery_resolution=""

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

# Convert a recovery value to a single markdown-safe line.
_normalize_recovery_value() {
	local value="$1"
	value="${value//$'\n'/ }"
	value="${value//$'\r'/ }"
	value="${value//|/\\|}"
	printf '%s' "$value"
	return 0
}

# Parse structured recovery fields into the module-scoped _save_recovery_* variables.
_parse_recovery_args() {
	local option=""
	local value=""
	while [[ $# -gt 0 ]]; do
		option="${1:-}"
		if [[ $# -lt 2 ]]; then
			print_error "${option} requires a value"
			return 1
		fi
		value="$(_normalize_recovery_value "${2:-}")"
		case "$option" in
		--session) _save_recovery_session="$value" ;;
		--objective) _save_recovery_objective="$value" ;;
		--directions) _save_recovery_directions="$value" ;;
		--trigger) _save_recovery_trigger="$value" ;;
		--completed) _save_recovery_completed="$value" ;;
		--remaining) _save_recovery_remaining="$value" ;;
		--unsafe-route) _save_recovery_unsafe_route="$value" ;;
		--next-safe-route) _save_recovery_next_route="$value" ;;
		--resume-condition) _save_recovery_resume_condition="$value" ;;
		--owner) _save_recovery_owner="$value" ;;
		--status) _save_recovery_status="$value" ;;
		*)
			print_error "Unknown recovery option: ${option}"
			return 1
			;;
		esac
		shift 2
	done

	case "$_save_recovery_status" in
	recovering | blocked) ;;
	*)
		print_error "--status must be recovering or blocked"
		return 1
		;;
	esac
	return 0
}

# Write the checkpoint markdown file using current _save_* variables.
# Expects _save_branch and _save_timestamp to be set by caller.
# Arguments:
#   $1 - output file path (defaults to current repo-scoped checkpoint)
_write_checkpoint_file() {
	local default_file=""
	default_file="$(checkpoint_file_for_current_scope)"
	local output_file="${1:-$default_file}"
	cat >"$output_file" <<EOF
# Session Checkpoint

Updated: ${_save_timestamp}

## Current State

| Field | Value |
|-------|-------|
| Current Task | ${_save_task:-none} |
| Repository Scope | ${_save_repo_scope:-unknown} |
| Branch | ${_save_branch} |
| Worktree | ${_save_worktree:-not set} |
| Batch/PR | ${_save_batch:-not set} |
| Elapsed | ${_save_elapsed:-unknown} min |
| Target | ${_save_target:-unknown} min |

## Next Tasks

${_save_next:-No next tasks specified}

## Context Note

${_save_note:-No additional context}

$(if [[ -n "$_save_recovery_status" ]]; then
	cat <<RECOVERY_EOF
### Safety-Stop Recovery

- **Session:** ${_save_recovery_session:-not yet known}
- **Original objective:** ${_save_recovery_objective:-not yet known}
- **Preserved user directions:** ${_save_recovery_directions:-not yet known}
- **Trigger and evidence:** ${_save_recovery_trigger:-not yet known}
- **Completed and verified:** ${_save_recovery_completed:-not yet known}
- **Remaining acceptance criteria:** ${_save_recovery_remaining:-not yet known}
- **Unsafe route not to repeat:** ${_save_recovery_unsafe_route:-not yet known}
- **Next safe route:** ${_save_recovery_next_route:-not yet known}
- **Resume condition:** ${_save_recovery_resume_condition:-not yet known}
- **Owner and status:** ${_save_recovery_owner:-not yet known} (${_save_recovery_status})
- **Resolution evidence:** ${_save_recovery_resolution:-not yet known}
RECOVERY_EOF
fi)

## Git Status

$(git status --short 2>/dev/null || echo "Not in a git repo")

## Recent Commits (this branch)

$(git log --oneline -5 2>/dev/null || echo "No commits")

## Open Worktrees

$(git worktree list 2>/dev/null || echo "No worktrees")
EOF
	return 0
}

_persist_checkpoint() {
	ensure_dir

	_save_timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	_save_repo_scope="$(checkpoint_scope_root)"
	local checkpoint_file=""
	checkpoint_file="$(checkpoint_file_for_current_scope)"

	# Auto-detect git state if not provided
	if [[ -z "$_save_branch" ]]; then
		_save_branch="$(current_branch_label)"
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
	if ! mv "$temp_file" "$checkpoint_file"; then
		rm -f "$temp_file"
		print_error "Failed to write checkpoint to ${checkpoint_file}"
		return 1
	fi

	print_success "Checkpoint saved: ${checkpoint_file}"
	print_info "Task: ${_save_task:-none} | Branch: ${_save_branch} | ${_save_timestamp}"
	return 0
}

cmd_save() {
	_parse_save_args "$@" || return 1
	_persist_checkpoint
	return $?
}

cmd_recovery_save() {
	_parse_save_args || return 1
	_parse_recovery_args "$@" || return 1
	_save_task="recovery:${_save_recovery_session:-unknown}"
	_save_next="${_save_recovery_next_route:-not yet known}"
	_save_note="Safety stop remains ${_save_recovery_status}; resume when ${_save_recovery_resume_condition:-not yet known}."
	_save_branch="$(current_branch_label)"
	_persist_checkpoint
	return $?
}

# Extract the value from a structured recovery bullet.
_recovery_field() {
	local checkpoint_file="$1"
	local label="$2"
	awk -v label="$label" '
		index($0, "- **" label ":** ") == 1 {
			sub("^- \\*\\*" label ":\\*\\* ", "")
			print
			exit
		}
	' "$checkpoint_file"
	return 0
}

_json_escape() {
	local value="$1"
	value="${value//\\/\\\\}"
	value="${value//\"/\\\"}"
	value="${value//$'\n'/\\n}"
	value="${value//$'\r'/\\r}"
	value="${value//$'\t'/\\t}"
	printf '%s' "$value"
	return 0
}

cmd_recovery_status() {
	local format="text"
	local option="${1:-}"
	[[ "$option" == "--json" ]] && format="$OUTPUT_FORMAT_JSON"
	local checkpoint_file=""
	checkpoint_file="$(checkpoint_file_for_current_scope)"
	if [[ ! -f "$checkpoint_file" ]] || ! grep -q '^### Safety-Stop Recovery$' "$checkpoint_file"; then
		if [[ "$format" == "$OUTPUT_FORMAT_JSON" ]]; then
			printf '{"status":"none","unresolved":false}\n'
		else
			print_info "No recovery checkpoint"
		fi
		return 0
	fi

	local owner_status=""
	local owner=""
	local status=""
	owner_status="$(_recovery_field "$checkpoint_file" "Owner and status")"
	owner="${owner_status% (*}"
	status="${owner_status##* (}"
	status="${status%)}"
	local unresolved="false"
	[[ "$status" == "recovering" || "$status" == "blocked" ]] && unresolved="true"

	if [[ "$format" == "$OUTPUT_FORMAT_JSON" ]]; then
		printf '{"status":"%s","unresolved":%s,"session":"%s","objective":"%s","remaining":"%s","nextSafeRoute":"%s","resumeCondition":"%s","owner":"%s","resolutionEvidence":"%s"}\n' \
			"$(_json_escape "$status")" \
			"$unresolved" \
			"$(_json_escape "$(_recovery_field "$checkpoint_file" "Session")")" \
			"$(_json_escape "$(_recovery_field "$checkpoint_file" "Original objective")")" \
			"$(_json_escape "$(_recovery_field "$checkpoint_file" "Remaining acceptance criteria")")" \
			"$(_json_escape "$(_recovery_field "$checkpoint_file" "Next safe route")")" \
			"$(_json_escape "$(_recovery_field "$checkpoint_file" "Resume condition")")" \
			"$(_json_escape "$owner")" \
			"$(_json_escape "$(_recovery_field "$checkpoint_file" "Resolution evidence")")"
	else
		printf 'Recovery status: %s\n' "$status"
		printf 'Remaining criteria: %s\n' "$(_recovery_field "$checkpoint_file" "Remaining acceptance criteria")"
		printf 'Next safe route: %s\n' "$(_recovery_field "$checkpoint_file" "Next safe route")"
	fi
	return 0
}

cmd_recovery_resolve() {
	local option="${1:-}"
	local evidence="${2:-}"
	if [[ "$option" != "--evidence" || -z "$evidence" ]]; then
		print_error "recovery-resolve requires --evidence <terminal evidence>"
		return 1
	fi
	evidence="$(_normalize_recovery_value "$evidence")"
	local checkpoint_file=""
	checkpoint_file="$(checkpoint_file_for_current_scope)"
	if [[ ! -f "$checkpoint_file" ]] || ! grep -q '^### Safety-Stop Recovery$' "$checkpoint_file"; then
		print_error "No recovery checkpoint to resolve"
		return 1
	fi

	local temp_file=""
	temp_file="$(mktemp "${CHECKPOINT_DIR}/checkpoint-resolve.XXXXXX")" || return 1
	awk -v evidence="$evidence" '
		/^- \*\*Owner and status:\*\*/ {
			sub(/ \((recovering|blocked)\)$/, " (resolved)")
		}
		/^- \*\*Resolution evidence:\*\*/ {
			print "- **Resolution evidence:** " evidence
			next
		}
		{ print }
	' "$checkpoint_file" >"$temp_file"
	sanitize_checkpoint "$temp_file"
	if ! mv "$temp_file" "$checkpoint_file"; then
		rm -f "$temp_file"
		print_error "Failed to resolve recovery checkpoint"
		return 1
	fi
	print_success "Recovery checkpoint resolved"
	return 0
}

cmd_load() {
	local checkpoint_file=""
	checkpoint_file="$(checkpoint_file_for_current_scope)"

	if [[ ! -f "$checkpoint_file" ]]; then
		print_warning "No checkpoint found at ${checkpoint_file}"
		if [[ -f "$LEGACY_CHECKPOINT_FILE" ]]; then
			print_warning "Legacy global checkpoint ignored for repo privacy isolation"
		fi
		print_info "Run: session-checkpoint-helper.sh save --task <id> --next <ids>"
		return 1
	fi

	cat "$checkpoint_file"

	# Auto-recall relevant memories after loading checkpoint
	local memory_helper="${SCRIPT_DIR}/memory-helper.sh"
	if [[ -x "$memory_helper" ]]; then
		echo ""
		echo "## Relevant Memories (repo-scoped)"
		echo ""

		# Recall only memories attached to the current repository scope. Global
		# --recent recall can replay unrelated private project details in a public
		# repo session.
		local repo_scope=""
		local repo_name=""
		local memories
		repo_scope="$(checkpoint_scope_root)"
		repo_name="$(basename "$repo_scope")"
		memories=$("$memory_helper" recall --query "$repo_name" --project "$repo_scope" --limit 5 --format text 2>/dev/null || echo "")

		if [[ -n "$memories" && "$memories" != *"No memories found"* ]]; then
			echo "$memories"
		else
			echo "No recent memories found."
		fi
	fi

	return 0
}

cmd_clear() {
	local checkpoint_file=""
	checkpoint_file="$(checkpoint_file_for_current_scope)"

	if [[ -f "$checkpoint_file" ]]; then
		rm "$checkpoint_file"
		print_success "Checkpoint cleared"
	else
		print_info "No checkpoint to clear"
	fi
	return 0
}

cmd_status() {
	local checkpoint_file=""
	checkpoint_file="$(checkpoint_file_for_current_scope)"

	if [[ ! -f "$checkpoint_file" ]]; then
		print_warning "No active checkpoint"
		return 1
	fi

	local file_age_seconds
	local now
	local file_mtime

	now="$(date +%s)"
	file_mtime="$(_file_mtime_epoch "$checkpoint_file")"
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
	current_task="$(awk -F'|' '/Current Task/ {gsub(/^[ \t]+|[ \t]+$/, "", $3); print $3; exit}' "$checkpoint_file" || echo "unknown")"
	local branch
	branch="$(awk -F'|' '/Branch/ {gsub(/^[ \t]+|[ \t]+$/, "", $3); print $3; exit}' "$checkpoint_file" || echo "unknown")"

	printf '%b\n' "${BOLD}Checkpoint Status${NC}"
	printf "  Age:    %s\n" "$age_display"
	printf "  Task:   %s\n" "$current_task"
	printf "  Branch: %s\n" "$branch"
	printf "  File:   %s\n" "$checkpoint_file"

	if [[ $file_age_seconds -gt 1800 ]]; then
		print_warning "  Warning: Checkpoint is stale (>30min). Consider updating."
	fi
	return 0
}

# Gather all state needed for a continuation prompt.
# Sets module-scoped _cont_* variables for use by cmd_continuation().
_gather_continuation_state() {
	_cont_repo_root="$(git rev-parse --show-toplevel 2>/dev/null || echo "unknown")"
	_cont_branch="$(current_branch_label)"
	_cont_repo_name="$(basename "$_cont_repo_root")"
	_cont_checkpoint_file="$(checkpoint_file_for_current_scope)"

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
	_cont_recovery_state="none"
	if [[ -f "$_cont_checkpoint_file" ]]; then
		_cont_checkpoint_note="$(awk '
			/^## Context Note$/ { capture = 1; next }
			capture && /^## / { exit }
			capture && NF { print }
		' "$_cont_checkpoint_file" || echo "")"
		if [[ -z "$_cont_checkpoint_note" ]]; then
			_cont_checkpoint_note="none"
		fi
		_cont_recovery_state="$(awk '
			/^### Safety-Stop Recovery$/ { capture = 1 }
			capture && /^## / { exit }
			capture { print }
		' "$_cont_checkpoint_file" || echo "")"
		[[ -z "$_cont_recovery_state" ]] && _cont_recovery_state="none"
	fi

	# Memory recall
	_cont_recent_memories="none"
	local memory_helper="${SCRIPT_DIR}/memory-helper.sh"
	if [[ -x "$memory_helper" ]]; then
		_cont_recent_memories="$(bash "$memory_helper" recall --query "$_cont_repo_name" --project "$_cont_repo_root" --limit 3 2>/dev/null || echo "none")"
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

**Safety-stop recovery state**:
${_cont_recovery_state}

**Repo-scoped memories**:
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
	recovery-save) cmd_recovery_save "$@" ;;
	recovery-resolve) cmd_recovery_resolve "$@" ;;
	recovery-status) cmd_recovery_status "$@" ;;
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
