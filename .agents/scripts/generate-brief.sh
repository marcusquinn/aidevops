#!/usr/bin/env bash
# generate-brief.sh — Generate a task brief from OpenCode session history
#
# Usage: generate-brief.sh <task_id> [project_root]
#
# Traces a task back to its source session in OpenCode's DB,
# extracts the conversation context, and generates a brief file.
#
# Output: todo/tasks/{task_id}-brief.md
#
# Dependencies: sqlite3, git, python3 (for JSON parsing)

set -euo pipefail

readonly OPENCODE_DB="${HOME}/.local/share/opencode/opencode.db"
readonly SUPERVISOR_DB="${HOME}/.aidevops/.agent-workspace/supervisor/supervisor.db"

# --- Helpers ---

log_info() { echo "[INFO] $*" >&2; }
log_warn() { echo "[WARN] $*" >&2; }
log_error() { echo "[ERROR] $*" >&2; }

usage() {
	echo "Usage: $0 <task_id> [project_root]"
	echo ""
	echo "Generates a task brief from OpenCode session history."
	echo "Output: {project_root}/todo/tasks/{task_id}-brief.md"
	exit 1
}

# --- Step 1: Find creation commit ---

find_creation_commit() {
	local task_id="$1"
	local project_root="$2"

	# Find the first commit that introduced this task ID in TODO.md
	local commit
	commit=$(git -C "$project_root" log --all --format="%H" -S "- [ ] ${task_id} " -- TODO.md 2>/dev/null | tail -1)

	if [[ -z "$commit" ]]; then
		# Try without the checkbox
		commit=$(git -C "$project_root" log --all --format="%H" -S "${task_id}" -- TODO.md 2>/dev/null | tail -1)
	fi

	echo "$commit"
}

get_commit_info() {
	local commit="$1"
	local project_root="$2"

	git -C "$project_root" log -1 --format="COMMIT_DATE=%ai%nCOMMIT_AUTHOR=%an%nCOMMIT_MSG=%s%nCOMMIT_EPOCH=%ct" "$commit" 2>/dev/null
}

# --- Step 2: Find OpenCode session ---

find_opencode_project_id() {
	local project_root="$1"

	if [[ ! -f "$OPENCODE_DB" ]]; then
		return 1
	fi

	sqlite3 "$OPENCODE_DB" "
		SELECT id FROM project WHERE worktree = '$project_root'
	" 2>/dev/null | head -1
}

find_session_by_timestamp() {
	local project_id="$1"
	local epoch_secs="$2"
	local epoch_ms=$((epoch_secs * 1000))

	if [[ ! -f "$OPENCODE_DB" ]]; then
		return 1
	fi

	# Find session that was active at this timestamp
	# (created before, updated after or within 1 hour)
	sqlite3 "$OPENCODE_DB" "
		SELECT s.id, s.title, s.parent_id,
		       datetime(s.time_created/1000, 'unixepoch') as created,
		       datetime(s.time_updated/1000, 'unixepoch') as updated
		FROM session s
		WHERE s.project_id = '$project_id'
		AND s.time_created <= $epoch_ms
		AND s.time_updated >= ($epoch_ms - 3600000)
		ORDER BY s.time_updated DESC
		LIMIT 1
	" 2>/dev/null
}

find_parent_session() {
	local session_id="$1"

	if [[ ! -f "$OPENCODE_DB" ]]; then
		return 1
	fi

	local parent_id
	parent_id=$(sqlite3 "$OPENCODE_DB" "
		SELECT parent_id FROM session WHERE id = '$session_id'
	" 2>/dev/null)

	if [[ -n "$parent_id" ]]; then
		sqlite3 "$OPENCODE_DB" "
			SELECT id, title, datetime(time_created/1000, 'unixepoch')
			FROM session WHERE id = '$parent_id'
		" 2>/dev/null
	fi
}

# --- Step 3: Extract conversation context ---

extract_session_context() {
	local session_id="$1"
	local task_id="$2"

	if [[ ! -f "$OPENCODE_DB" ]]; then
		return 1
	fi

	# Find user messages that mention this task or were around the creation time
	# Extract summary titles and diff content
	python3 -c "
import sqlite3, json, sys, re

db = sqlite3.connect('$OPENCODE_DB')
cursor = db.cursor()

# Get all user messages from this session
cursor.execute('''
    SELECT m.data, m.time_created
    FROM message m
    WHERE m.session_id = ?
    AND json_extract(m.data, '\$.role') = 'user'
    ORDER BY m.time_created
''', ('$session_id',))

task_id = '$task_id'
context_parts = []

for row in cursor.fetchall():
    try:
        data = json.loads(row[0])
        summary = data.get('summary', {})
        title = summary.get('title', '')
        diffs = summary.get('diffs', [])

        # Check if this message's diff added the task
        for diff in diffs:
            after = diff.get('after', '')
            before = diff.get('before', '')
            if task_id in after and task_id not in before:
                # This message created the task — extract the full block
                lines = after.split('\n')
                capturing = False
                task_block = []
                # Find the task line and determine its indent level
                task_indent = -1
                for i, line in enumerate(lines):
                    # Match the task line (with or without checkbox)
                    if re.search(rf'- \[.\] {re.escape(task_id)} ', line):
                        capturing = True
                        task_indent = len(line) - len(line.lstrip())
                        task_block.append(line)
                        continue
                    if capturing:
                        stripped = line.lstrip()
                        current_indent = len(line) - len(stripped)
                        # Continue capturing if:
                        # - line is blank (preserve structure)
                        # - line is more indented than the task line
                        if line.strip() == '':
                            # Blank line: peek ahead to see if next non-blank
                            # line is still part of this block
                            still_in_block = False
                            for j in range(i + 1, min(i + 3, len(lines))):
                                if lines[j].strip():
                                    next_indent = len(lines[j]) - len(lines[j].lstrip())
                                    if next_indent > task_indent:
                                        still_in_block = True
                                    break
                            if still_in_block:
                                task_block.append(line)
                            else:
                                break
                        elif current_indent > task_indent:
                            task_block.append(line)
                        else:
                            # Same or less indent = new task or section
                            break

                if task_block:
                    context_parts.append('TASK_BLOCK_START')
                    context_parts.extend(task_block)
                    context_parts.append('TASK_BLOCK_END')

                context_parts.append(f'MESSAGE_TITLE={title}')
                break
    except (json.JSONDecodeError, KeyError):
        continue

db.close()

if context_parts:
    print('\n'.join(context_parts))
else:
    print('NO_CONTEXT_FOUND')
" 2>/dev/null
}

# --- Step 4: Check supervisor DB ---

find_supervisor_context() {
	local task_id="$1"

	if [[ ! -f "$SUPERVISOR_DB" ]]; then
		return 0
	fi

	# Exact match on task ID only — LIKE is too loose and matches unrelated tasks
	sqlite3 "$SUPERVISOR_DB" "
		SELECT id, description, session_id, created_at, completed_at
		FROM tasks
		WHERE id = '$task_id'
		LIMIT 1
	" 2>/dev/null
}

# --- Step 5: Generate brief ---

generate_brief() {
	local task_id="$1"
	local project_root="$2"
	local output_file="$project_root/todo/tasks/${task_id}-brief.md"

	mkdir -p "$project_root/todo/tasks"

	# Find creation commit
	local commit
	commit=$(find_creation_commit "$task_id" "$project_root")
	if [[ -z "$commit" ]]; then
		log_warn "No creation commit found for $task_id"
		return 1
	fi

	# Get commit info
	local commit_date="" commit_author="" commit_msg="" commit_epoch=""
	while IFS='=' read -r key value; do
		case "$key" in
		COMMIT_DATE) commit_date="$value" ;;
		COMMIT_AUTHOR) commit_author="$value" ;;
		COMMIT_MSG) commit_msg="$value" ;;
		COMMIT_EPOCH) commit_epoch="$value" ;;
		esac
	done <<<"$(get_commit_info "$commit" "$project_root")"

	log_info "$task_id: commit $commit ($commit_date) by $commit_author"

	# Find OpenCode session
	local session_id="" session_title="" parent_session=""
	local project_id
	project_id=$(find_opencode_project_id "$project_root")

	if [[ -n "$project_id" && -n "$commit_epoch" ]]; then
		local session_info
		session_info=$(find_session_by_timestamp "$project_id" "$commit_epoch")
		if [[ -n "$session_info" ]]; then
			session_id=$(echo "$session_info" | cut -d'|' -f1)
			session_title=$(echo "$session_info" | cut -d'|' -f2)
			local parent_id
			parent_id=$(echo "$session_info" | cut -d'|' -f3)

			if [[ -n "$parent_id" ]]; then
				parent_session=$(find_parent_session "$session_id")
			fi

			log_info "$task_id: session $session_id '$session_title'"
		fi
	fi

	# Extract conversation context
	local context="NO_CONTEXT_FOUND"
	local search_session="${session_id}"

	# If this was a subagent commit session, search the parent
	if [[ "$session_title" == *"subagent"* && -n "$parent_session" ]]; then
		search_session=$(echo "$parent_session" | cut -d'|' -f1)
		local parent_title
		parent_title=$(echo "$parent_session" | cut -d'|' -f2)
		log_info "$task_id: searching parent session '$parent_title'"
	fi

	if [[ -n "$search_session" ]]; then
		context=$(extract_session_context "$search_session" "$task_id")
	fi

	# Check supervisor DB
	local supervisor_info=""
	supervisor_info=$(find_supervisor_context "$task_id")

	# Extract task description from TODO.md
	local task_line=""
	task_line=$(grep -E "^\s*- \[.\] ${task_id} " "$project_root/TODO.md" 2>/dev/null | head -1)
	local task_title=""
	task_title=$(echo "$task_line" | sed -E 's/^.*\] t[0-9]+(\.[0-9]+)* //' | sed -E 's/ #.*//' | sed -E 's/ ~.*//')

	# Extract task block (subtasks/notes) from TODO.md
	# Captures the task line and all lines more indented than it
	local task_block=""
	task_block=$(python3 -c "
import re, sys
task_id = '$task_id'
lines = open('$project_root/TODO.md').readlines()
capturing = False
task_indent = -1
block = []
for i, line in enumerate(lines):
    rline = line.rstrip('\n')
    if re.search(rf'- \[.\] {re.escape(task_id)} ', rline):
        capturing = True
        task_indent = len(rline) - len(rline.lstrip())
        block.append(rline)
        continue
    if capturing:
        if rline.strip() == '':
            # Blank line: check if next non-blank is still indented
            still_in = False
            for j in range(i + 1, min(i + 3, len(lines))):
                nxt = lines[j].rstrip('\n')
                if nxt.strip():
                    if (len(nxt) - len(nxt.lstrip())) > task_indent:
                        still_in = True
                    break
            if still_in:
                block.append(rline)
            else:
                break
        elif (len(rline) - len(rline.lstrip())) > task_indent:
            block.append(rline)
        else:
            break
print('\n'.join(block))
" 2>/dev/null)

	# Extract REBASE comment
	local rebase_note=""
	rebase_note=$(echo "$task_line" | grep -oE '<!-- REBASE:[^>]+-->' | sed 's/<!-- REBASE: //;s/ -->//' || true)

	# Determine session origin string
	local session_origin="unknown"
	if [[ -n "$session_id" ]]; then
		if [[ -n "$parent_session" ]]; then
			local parent_id parent_title
			parent_id=$(echo "$parent_session" | cut -d'|' -f1)
			parent_title=$(echo "$parent_session" | cut -d'|' -f2)
			session_origin="opencode:${parent_id} '${parent_title}' (committed via subagent ${session_id})"
		else
			session_origin="opencode:${session_id} '${session_title}'"
		fi
	elif [[ -n "$supervisor_info" ]]; then
		local sup_session
		sup_session=$(echo "$supervisor_info" | cut -d'|' -f3)
		session_origin="supervisor:${sup_session} (headless Claude CLI)"
	elif [[ "$commit_author" != "marcusquinn" ]]; then
		session_origin="external contributor ($commit_author)"
	fi

	# Determine created_by — supervisor match must be exact (id field only)
	local created_by="ai-interactive"
	local sup_id=""
	if [[ -n "$supervisor_info" ]]; then
		sup_id=$(echo "$supervisor_info" | cut -d'|' -f1)
	fi
	if [[ -n "$sup_id" && "$sup_id" == "$task_id" ]]; then
		created_by="ai-supervisor"
	elif [[ "$commit_author" != "marcusquinn" && "$commit_author" != "GitHub Actions" ]]; then
		created_by="human ($commit_author)"
	fi

	# Check for parent task
	local parent_task=""
	if echo "$task_id" | grep -qE '\.'; then
		parent_task=$(echo "$task_id" | sed -E 's/\.[0-9]+$//')
	fi

	# Extract context block from session data
	local context_block=""
	if [[ "$context" != "NO_CONTEXT_FOUND" ]]; then
		local msg_title
		msg_title=$(echo "$context" | grep '^MESSAGE_TITLE=' | head -1 | sed 's/MESSAGE_TITLE=//')
		local task_content
		task_content=$(echo "$context" | sed -n '/^TASK_BLOCK_START$/,/^TASK_BLOCK_END$/p' | grep -v 'TASK_BLOCK_')
		if [[ -n "$task_content" ]]; then
			context_block="$task_content"
		fi
		if [[ -n "$msg_title" ]]; then
			session_origin="${session_origin} — message: '${msg_title}'"
		fi
	fi

	# Prefer session context block over TODO.md extraction (session has original rich content)
	local best_block="${context_block:-${task_block:-${task_line}}}"

	# Write the brief
	cat >"$output_file" <<BRIEF
---
mode: subagent
---
# ${task_id}: ${task_title}

## Origin

- **Created:** ${commit_date%% *}
- **Session:** ${session_origin}
- **Created by:** ${created_by}
$(if [[ -n "$parent_task" ]]; then echo "- **Parent task:** ${parent_task} — see [todo/tasks/${parent_task}-brief.md](${parent_task}-brief.md)"; fi)
- **Commit:** ${commit} — "${commit_msg}"

## What

${task_title}

## Specification

\`\`\`markdown
${best_block}
\`\`\`
$(if [[ -n "$context_block" && -n "$task_block" && "$context_block" != "$task_block" ]]; then echo "
## Current TODO.md State

\`\`\`markdown
${task_block}
\`\`\`"; fi)
$(if [[ -n "$rebase_note" ]]; then echo "
## Implementation Notes (from REBASE)

${rebase_note}"; fi)
$(if [[ -n "$supervisor_info" && "$sup_id" == "$task_id" ]]; then echo "
## Supervisor Context

\`\`\`
${supervisor_info}
\`\`\`"; fi)

## Acceptance Criteria

- [ ] Implementation matches the specification above
- [ ] Tests pass
- [ ] Lint clean

## Relevant Files

<!-- TODO: Add relevant file paths after codebase analysis -->
BRIEF

	log_info "$task_id: brief written to $output_file"
	return 0
}

# --- Main ---

main() {
	local task_id="${1:-}"
	local project_root="${2:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

	if [[ -z "$task_id" ]]; then
		usage
	fi

	if [[ "$task_id" == "--all" ]]; then
		# Generate briefs for all open tasks without briefs
		local count=0
		while IFS= read -r line; do
			local tid
			tid=$(echo "$line" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1)
			if [[ -n "$tid" && ! -f "$project_root/todo/tasks/${tid}-brief.md" ]]; then
				generate_brief "$tid" "$project_root" || true
				count=$((count + 1))
			fi
		done < <(grep -E '^\s*- \[ \] t[0-9]' "$project_root/TODO.md")
		log_info "Generated $count briefs"
	else
		generate_brief "$task_id" "$project_root"
	fi
}

main "$@"
