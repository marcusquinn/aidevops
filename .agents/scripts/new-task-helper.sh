#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# new-task-helper.sh — Batch task creation helper for /new-task
# Part of aidevops framework: https://aidevops.sh
#
# Usage:
#   new-task-helper.sh batch --title "Title 1" --title "Title 2"
#   new-task-helper.sh batch --from-file titles.txt
#   echo -e "Title 1\nTitle 2" | new-task-helper.sh batch
#
# Options (batch subcommand):
#   --title "..."     Task title (may be repeated for multiple tasks)
#   --from-file FILE  File with one title per line (- for stdin)
#   --labels "..."    Comma-separated labels applied to all tasks (optional)
#   --dry-run         Preview allocations without making changes
#   --no-issue        Skip GitHub/GitLab issue creation
#   --offline         Force offline mode
#   --repo-path PATH  Path to git repository (default: current directory)
#
# Output:
#   Prints a summary table: ID | Title | GH# (or offline)
#   Emits a single git commit + push for all planning files.
#
# Exit codes:
#   0 - All tasks created successfully
#   1 - Error (see stderr)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared helpers if available
if [[ -f "$SCRIPT_DIR/shared-constants.sh" ]]; then
	# shellcheck source=/dev/null
	source "$SCRIPT_DIR/shared-constants.sh"
fi

# Logging helpers (inline if shared-constants not sourced)
if ! command -v log_info >/dev/null 2>&1; then
	log_info() {
		echo "[INFO] $*" >&2
		return 0
	}
	log_success() {
		echo "[OK]   $*" >&2
		return 0
	}
	log_warn() {
		echo "[WARN] $*" >&2
		return 0
	}
	log_error() {
		echo "[ERR]  $*" >&2
		return 0
	}
fi

# ---------------------------------------------------------------------------
# _create_stub_brief: write a minimal brief file for a batch-allocated task
# ---------------------------------------------------------------------------
_create_stub_brief() {
	local task_id="$1"
	local title="$2"
	local task_ref="$3"
	local repo_path="$4"
	local today
	today=$(date +%Y-%m-%d)

	local brief_dir="$repo_path/todo/tasks"
	local brief_path="$brief_dir/${task_id}-brief.md"

	# Create directory if needed
	mkdir -p "$brief_dir"

	# Skip if brief already exists
	if [[ -f "$brief_path" ]]; then
		log_warn "Brief already exists: $brief_path — skipping"
		return 0
	fi

	cat >"$brief_path" <<EOF
# ${task_id}: ${title}

## Origin

- **Created:** ${today}
- **Session:** ${CLAUDE_SESSION_ID:-batch-${today}}
- **Created by:** ai-interactive (batch mode via /new-task --batch)
- **Task ref:** ${task_ref}

## What

<!-- TODO: Describe the deliverable clearly — what it must produce, not just "implement X". -->
${title}

## Why

<!-- TODO: Problem being solved, user need, business value, or dependency. -->

## Tier

**Selected tier:** \`tier:standard\`

## How (Approach)

### Files to Modify

<!-- TODO: List files to modify with NEW:/EDIT: prefixes and line ranges. -->

### Implementation Steps

<!-- TODO: Numbered, concrete steps. Workers follow these directly. -->

1. (fill in)

### Verification

\`\`\`bash
# TODO: commands to verify the implementation is correct
\`\`\`

## Acceptance Criteria

- [ ] Implementation matches the What section
- [ ] Tests pass
- [ ] Lint clean (shellcheck for shell scripts)

## Context

<!-- TODO: Key decisions, constraints, things ruled out. -->
Created via \`/new-task --batch\`. Fill in How section before dispatching.
EOF

	return 0
}

# ---------------------------------------------------------------------------
# _append_todo_entry: append a single task line to TODO.md
# ---------------------------------------------------------------------------
_append_todo_entry() {
	local task_id="$1"
	local title="$2"
	local task_ref="$3"
	local todo_file="$4"
	local today
	today=$(date +%Y-%m-%d)

	local ref_field=""
	if [[ -n "$task_ref" && "$task_ref" != "offline" ]]; then
		ref_field=" ref:${task_ref}"
	fi

	local entry="- [ ] ${task_id} ${title} #auto-dispatch ~1h${ref_field} logged:${today}"

	# Append under the first "## " section header that looks like an active backlog
	# If no suitable header, append at end of file
	if [[ -f "$todo_file" ]]; then
		echo "$entry" >>"$todo_file"
	else
		log_error "TODO.md not found at: $todo_file"
		return 1
	fi

	return 0
}

# ---------------------------------------------------------------------------
# cmd_batch: main batch creation flow
# ---------------------------------------------------------------------------
cmd_batch() {
	local -a titles=()
	local from_file=""
	local labels=""
	local dry_run=false
	local no_issue=false
	local offline=false
	local repo_path=""

	# Parse arguments
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--title)
			titles+=("$2")
			shift 2
			;;
		--from-file)
			from_file="$2"
			shift 2
			;;
		--labels)
			labels="$2"
			shift 2
			;;
		--dry-run)
			dry_run=true
			shift
			;;
		--no-issue)
			no_issue=true
			shift
			;;
		--offline)
			offline=true
			shift
			;;
		--repo-path)
			repo_path="$2"
			shift 2
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	# Read titles from file or stdin if --from-file given
	if [[ -n "$from_file" ]]; then
		if [[ "$from_file" == "-" ]]; then
			while IFS= read -r line; do
				line="${line%%#*}"                      # strip inline comments
				line="${line#"${line%%[![:space:]]*}"}" # ltrim
				line="${line%"${line##*[![:space:]]}"}" # rtrim
				[[ -n "$line" ]] && titles+=("$line")
			done
		else
			if [[ ! -f "$from_file" ]]; then
				log_error "File not found: $from_file"
				return 1
			fi
			while IFS= read -r line; do
				line="${line%%#*}"
				line="${line#"${line%%[![:space:]]*}"}"
				line="${line%"${line##*[![:space:]]}"}"
				[[ -n "$line" ]] && titles+=("$line")
			done <"$from_file"
		fi
	fi

	# If no titles yet and stdin is a pipe, read from stdin
	if [[ ${#titles[@]} -eq 0 ]] && ! [[ -t 0 ]]; then
		while IFS= read -r line; do
			line="${line%%#*}"
			line="${line#"${line%%[![:space:]]*}"}"
			line="${line%"${line##*[![:space:]]}"}"
			[[ -n "$line" ]] && titles+=("$line")
		done
	fi

	if [[ ${#titles[@]} -eq 0 ]]; then
		log_error "No titles provided. Use --title, --from-file, or pipe titles on stdin."
		echo "Usage: new-task-helper.sh batch --title \"Title 1\" --title \"Title 2\"" >&2
		echo "       new-task-helper.sh batch --from-file titles.txt" >&2
		printf "       printf 'Title 1\\\\nTitle 2\\\\n' | new-task-helper.sh batch\n" >&2
		return 1
	fi

	# Resolve repo path
	if [[ -z "$repo_path" ]]; then
		repo_path=$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")
	fi
	local todo_file="$repo_path/TODO.md"

	local claim_script="$SCRIPT_DIR/claim-task-id.sh"
	if [[ ! -x "$claim_script" ]]; then
		log_error "claim-task-id.sh not found or not executable: $claim_script"
		return 1
	fi

	log_info "Batch creating ${#titles[@]} task(s)..."
	if [[ "$dry_run" == "true" ]]; then
		log_info "[DRY-RUN] No changes will be made"
	fi

	# Summary table data: parallel arrays
	local -a result_ids=()
	local -a result_titles=()
	local -a result_refs=()
	local any_failed=false

	for title in "${titles[@]}"; do
		log_info "Allocating: $title"

		if [[ "$dry_run" == "true" ]]; then
			result_ids+=("[dry-run]")
			result_titles+=("$title")
			result_refs+=("[dry-run]")
			continue
		fi

		# Build claim args
		local -a claim_args=(--title "$title" --repo-path "$repo_path")
		[[ -n "$labels" ]] && claim_args+=(--labels "$labels")
		[[ "$no_issue" == "true" ]] && claim_args+=(--no-issue)
		[[ "$offline" == "true" ]] && claim_args+=(--offline)

		local claim_output=""
		local claim_rc=0
		claim_output=$("$claim_script" "${claim_args[@]}" 2>/dev/null) || claim_rc=$?

		if [[ $claim_rc -ne 0 && $claim_rc -ne 2 ]]; then
			log_error "Failed to allocate ID for: $title (exit code: $claim_rc)"
			any_failed=true
			continue
		fi

		# Parse output
		local task_id="" task_ref=""
		while IFS= read -r line; do
			case "$line" in
			task_id=*) task_id="${line#task_id=}" ;;
			ref=*) task_ref="${line#ref=}" ;;
			esac
		done <<<"$claim_output"

		if [[ -z "$task_id" ]]; then
			log_error "No task_id returned for: $title"
			any_failed=true
			continue
		fi

		# Create stub brief
		_create_stub_brief "$task_id" "$title" "$task_ref" "$repo_path" || {
			log_warn "Brief creation failed for $task_id — continuing"
		}

		# Append TODO entry
		_append_todo_entry "$task_id" "$title" "$task_ref" "$todo_file" || {
			log_warn "TODO entry failed for $task_id — continuing"
		}

		result_ids+=("$task_id")
		result_titles+=("$title")
		result_refs+=("${task_ref:-offline}")
		log_success "Allocated $task_id ($task_ref): $title"
	done

	# Single commit+push for all planning files
	if [[ "$dry_run" == "false" && ${#result_ids[@]} -gt 0 ]]; then
		local planning_helper="$SCRIPT_DIR/planning-commit-helper.sh"
		if [[ -x "$planning_helper" ]]; then
			local n="${#result_ids[@]}"
			local commit_msg="plan: batch add ${n} task(s) via /new-task --batch"
			log_info "Committing $n planning file(s)..."
			"$planning_helper" "$commit_msg" || log_warn "Planning commit failed — files written but not committed"
		else
			# Fallback: direct git commit
			local n="${#result_ids[@]}"
			log_info "planning-commit-helper.sh not found, using direct git commit..."
			git -C "$repo_path" add TODO.md "todo/tasks/" 2>/dev/null || true
			git -C "$repo_path" commit -m "plan: batch add ${n} task(s) via /new-task --batch" 2>/dev/null || true
			git -C "$repo_path" push 2>/dev/null || log_warn "Push failed — committed locally"
		fi
	fi

	# Print summary table
	echo ""
	printf "%-12s %-55s %s\n" "ID" "Title" "GH#"
	printf "%-12s %-55s %s\n" "------------" "-------------------------------------------------------" "-------"
	local i=0
	while [[ $i -lt ${#result_ids[@]} ]]; do
		local tid="${result_ids[$i]}"
		local ttitle="${result_titles[$i]}"
		local tref="${result_refs[$i]}"
		# Truncate title if too long for display
		if [[ ${#ttitle} -gt 55 ]]; then
			ttitle="${ttitle:0:52}..."
		fi
		printf "%-12s %-55s %s\n" "$tid" "$ttitle" "$tref"
		i=$((i + 1))
	done
	echo ""

	if [[ "$any_failed" == "true" ]]; then
		log_warn "Some tasks failed to allocate — check stderr above"
		return 1
	fi

	log_success "Batch complete: ${#result_ids[@]} task(s) created"
	return 0
}

# ---------------------------------------------------------------------------
# cmd_help
# ---------------------------------------------------------------------------
cmd_help() {
	cat <<'EOF'
new-task-helper.sh — Batch task creation for /new-task

Usage:
  new-task-helper.sh batch [options]

Subcommands:
  batch    Create multiple tasks in one pass with a single commit+push

Options (batch):
  --title "..."     Task title (repeat for multiple tasks)
  --from-file FILE  File with one title per line (use - for stdin)
  --labels "..."    Comma-separated labels applied to all tasks
  --dry-run         Preview allocations without changes
  --no-issue        Skip GitHub/GitLab issue creation
  --offline         Force offline mode
  --repo-path PATH  Git repository path (default: current directory)

Examples:
  new-task-helper.sh batch --title "Fix login bug" --title "Add CSV export"
  new-task-helper.sh batch --from-file sprint-tasks.txt
  echo -e "Fix auth\nAdd export" | new-task-helper.sh batch --labels "sprint-3"

Output:
  ID           Title                                                   GH#
  ------------ ------------------------------------------------------- -------
  t1234        Fix login bug                                           GH#5001
  t1235        Add CSV export                                          GH#5002
EOF
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
	local command="${1:-help}"
	shift || true
	case "$command" in
	batch) cmd_batch "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		log_error "Unknown command: $command"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
