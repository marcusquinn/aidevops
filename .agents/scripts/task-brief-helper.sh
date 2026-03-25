#!/usr/bin/env bash
# task-brief-helper.sh — Generate a task brief from OpenCode session history
#
# Usage: task-brief-helper.sh <task_id> [project_root]
#        task-brief-helper.sh --all [project_root]
#
# Traces a task back to its source session in OpenCode's DB,
# extracts the conversation context, and generates a brief file.
#
# Output: todo/tasks/{task_id}-brief.md
#
# Dependencies: git, python3 (DB access via sqlite3 module, JSON parsing, task block extraction)

set -euo pipefail

readonly OPENCODE_DB="${HOME}/.local/share/opencode/opencode.db"
readonly SUPERVISOR_DB="${HOME}/.aidevops/.agent-workspace/supervisor/supervisor.db"

# --- Helpers ---

log_info() {
	echo "[INFO] $*" >&2
	return 0
}
log_warn() {
	echo "[WARN] $*" >&2
	return 0
}
log_error() {
	echo "[ERROR] $*" >&2
	return 0
}

usage() {
	echo "Usage: $0 <task_id> [project_root]"
	echo "       $0 --all [project_root]"
	echo ""
	echo "Generates a task brief from OpenCode session history."
	echo "Output: {project_root}/todo/tasks/{task_id}-brief.md"
	return 1
}

# Validate task_id format to prevent injection
validate_task_id() {
	local task_id
	task_id="$1"
	if [[ ! "$task_id" =~ ^t[0-9]+(\.[0-9]+)*$ ]]; then
		log_error "Invalid task ID format: $task_id (expected tNNN or tNNN.N)"
		return 1
	fi
	return 0
}

# --- Step 1: Find creation commit ---

find_creation_commit() {
	local task_id
	local project_root
	task_id="$1"
	project_root="$2"

	# Find the first commit that introduced this task ID in TODO.md
	local commit
	commit=$(git -C "$project_root" log --all --format="%H" -S "- [ ] ${task_id} " -- TODO.md 2>/dev/null | grep -E '^[0-9a-f]{40}$' | tail -1) || true

	if [[ -z "$commit" ]]; then
		# Try without the checkbox
		commit=$(git -C "$project_root" log --all --format="%H" -S "${task_id}" -- TODO.md 2>/dev/null | grep -E '^[0-9a-f]{40}$' | tail -1) || true
	fi

	echo "$commit"
	return 0
}

get_commit_info() {
	local commit
	local project_root
	commit="$1"
	project_root="$2"

	git -C "$project_root" log -1 --format="COMMIT_DATE=%ai%nCOMMIT_AUTHOR=%an%nCOMMIT_MSG=%s%nCOMMIT_EPOCH=%ct" "$commit" 2>/dev/null || true
	return 0
}

# --- Step 2: Find OpenCode session ---

find_opencode_project_id() {
	local project_root
	project_root="$1"

	if [[ ! -f "$OPENCODE_DB" ]]; then
		return 1
	fi

	# Use env var to pass project_root safely — parameterized query prevents injection
	BRIEF_OPENCODE_DB="$OPENCODE_DB" BRIEF_PROJECT_ROOT="$project_root" python3 -c "
import sqlite3, os
db = sqlite3.connect(os.environ['BRIEF_OPENCODE_DB'])
db.execute('PRAGMA journal_mode=WAL')
db.execute('PRAGMA busy_timeout=5000')
cursor = db.cursor()
cursor.execute('SELECT id FROM project WHERE worktree = ?', (os.environ['BRIEF_PROJECT_ROOT'],))
row = cursor.fetchone()
if row:
    print(row[0])
db.close()
" 2>/dev/null | head -1
	return 0
}

find_session_by_timestamp() {
	local project_id
	local epoch_secs
	local epoch_ms
	project_id="$1"
	epoch_secs="$2"
	epoch_ms=$((epoch_secs * 1000))

	if [[ ! -f "$OPENCODE_DB" ]]; then
		return 1
	fi

	# Use env vars to pass parameters safely — parameterized query prevents injection
	BRIEF_OPENCODE_DB="$OPENCODE_DB" BRIEF_PROJECT_ID="$project_id" BRIEF_EPOCH_MS="$epoch_ms" python3 -c "
import sqlite3, os
db = sqlite3.connect(os.environ['BRIEF_OPENCODE_DB'])
db.execute('PRAGMA journal_mode=WAL')
db.execute('PRAGMA busy_timeout=5000')
cursor = db.cursor()
project_id = os.environ['BRIEF_PROJECT_ID']
epoch_ms = int(os.environ['BRIEF_EPOCH_MS'])
cursor.execute('''
    SELECT s.id, s.title, s.parent_id,
           datetime(s.time_created/1000, 'unixepoch') as created,
           datetime(s.time_updated/1000, 'unixepoch') as updated
    FROM session s
    WHERE s.project_id = ?
    AND s.time_created <= ?
    AND s.time_updated >= (? - 3600000)
    ORDER BY s.time_updated DESC
    LIMIT 1
''', (project_id, epoch_ms, epoch_ms))
row = cursor.fetchone()
if row:
    print('|'.join(str(x) if x else '' for x in row))
db.close()
" 2>/dev/null | head -1
	return 0
}

find_parent_session() {
	local session_id
	session_id="$1"

	if [[ ! -f "$OPENCODE_DB" ]]; then
		return 1
	fi

	BRIEF_OPENCODE_DB="$OPENCODE_DB" BRIEF_SESSION_ID="$session_id" python3 -c "
import sqlite3, os
db = sqlite3.connect(os.environ['BRIEF_OPENCODE_DB'])
db.execute('PRAGMA journal_mode=WAL')
db.execute('PRAGMA busy_timeout=5000')
cursor = db.cursor()
session_id = os.environ['BRIEF_SESSION_ID']
cursor.execute('SELECT parent_id FROM session WHERE id = ?', (session_id,))
row = cursor.fetchone()
if row and row[0]:
    cursor.execute(\"SELECT id, title, datetime(time_created/1000, 'unixepoch') FROM session WHERE id = ?\", (row[0],))
    parent = cursor.fetchone()
    if parent:
        print('|'.join(str(x) if x else '' for x in parent))
db.close()
" 2>/dev/null | head -1
	return 0
}

# --- Step 3: Extract conversation context ---

# Python helper: scan user messages in a session and find the diff that added task_id.
# Prints the task block lines bracketed by TASK_BLOCK_START/END and a MESSAGE_TITLE= line.
# Called via env vars to prevent injection.
_python_extract_task_block() {
	python3 -c "
import sqlite3, json, re, os

def _peek_next_indent(lines, i, task_indent):
    '''Return True if the next non-blank line after index i is more indented than task_indent.'''
    for j in range(i + 1, min(i + 3, len(lines))):
        if lines[j].strip():
            next_indent = len(lines[j]) - len(lines[j].lstrip())
            return next_indent > task_indent
    return False

def _extract_block_from_diff(after, task_id):
    '''Extract the task block lines from a diff's after-text.'''
    lines = after.split('\n')
    capturing = False
    task_block = []
    task_indent = -1
    for i, line in enumerate(lines):
        if re.search(rf'- \[.\] {re.escape(task_id)} ', line):
            capturing = True
            task_indent = len(line) - len(line.lstrip())
            task_block.append(line)
            continue
        if capturing:
            current_indent = len(line) - len(line.lstrip())
            if line.strip() == '':
                if _peek_next_indent(lines, i, task_indent):
                    task_block.append(line)
                else:
                    break
            elif current_indent > task_indent:
                task_block.append(line)
            else:
                break
    result = []
    if task_block:
        result.append('TASK_BLOCK_START')
        result.extend(task_block)
        result.append('TASK_BLOCK_END')
    return result

db_path = os.environ['BRIEF_OPENCODE_DB']
session_id = os.environ['BRIEF_SESSION_ID']
task_id = os.environ['BRIEF_TASK_ID']

db = sqlite3.connect(db_path)
db.execute('PRAGMA journal_mode=WAL')
db.execute('PRAGMA busy_timeout=5000')
cursor = db.cursor()

cursor.execute('''
    SELECT m.data, m.time_created
    FROM message m
    WHERE m.session_id = ?
    AND json_extract(m.data, '\$.role') = 'user'
    ORDER BY m.time_created
''', (session_id,))

context_parts = []
for row in cursor.fetchall():
    try:
        data = json.loads(row[0])
        summary = data.get('summary', {})
        title = summary.get('title', '')
        diffs = summary.get('diffs', [])
        for diff in diffs:
            after = diff.get('after', '')
            before = diff.get('before', '')
            if task_id in after and task_id not in before:
                context_parts.extend(_extract_block_from_diff(after, task_id))
                context_parts.append(f'MESSAGE_TITLE={title}')
                break
    except (json.JSONDecodeError, KeyError):
        continue

db.close()
print('\n'.join(context_parts) if context_parts else 'NO_CONTEXT_FOUND')
" 2>/dev/null || echo "NO_CONTEXT_FOUND"
	return 0
}

extract_session_context() {
	local session_id
	local task_id
	session_id="$1"
	task_id="$2"

	if [[ ! -f "$OPENCODE_DB" ]]; then
		return 1
	fi

	# Pass all parameters via environment variables to prevent injection
	BRIEF_SESSION_ID="$session_id" BRIEF_TASK_ID="$task_id" BRIEF_OPENCODE_DB="$OPENCODE_DB" \
		_python_extract_task_block
	return 0
}

# --- Step 4: Check supervisor DB ---

find_supervisor_context() {
	local task_id
	task_id="$1"

	if [[ ! -f "$SUPERVISOR_DB" ]]; then
		return 0
	fi

	# Exact match on task ID only — parameterized query prevents injection
	BRIEF_TASK_ID="$task_id" BRIEF_SUPERVISOR_DB="$SUPERVISOR_DB" python3 -c "
import sqlite3, os
db_path = os.environ['BRIEF_SUPERVISOR_DB']
task_id = os.environ['BRIEF_TASK_ID']
db = sqlite3.connect(db_path)
db.execute('PRAGMA journal_mode=WAL')
db.execute('PRAGMA busy_timeout=5000')
cursor = db.cursor()
cursor.execute('SELECT id, description, session_id, created_at, completed_at FROM tasks WHERE id = ? LIMIT 1', (task_id,))
row = cursor.fetchone()
if row:
    print('|'.join(str(x) if x is not None else '' for x in row))
db.close()
" 2>/dev/null | head -1
	return 0
}

# --- Step 5: Generate brief (decomposed) ---

# Resolve commit fields into named variables written to stdout as KEY=VALUE lines.
_resolve_commit_info() {
	local task_id
	local project_root
	task_id="$1"
	project_root="$2"

	local commit
	commit=$(find_creation_commit "$task_id" "$project_root")
	if [[ -z "$commit" ]]; then
		log_warn "No creation commit found for $task_id"
		return 1
	fi

	echo "COMMIT=$commit"
	get_commit_info "$commit" "$project_root"
	return 0
}

# Resolve session info given a project_id and commit epoch.
# Outputs: SESSION_ID, SESSION_TITLE, PARENT_SESSION (pipe-delimited raw), SEARCH_SESSION
_resolve_session_info() {
	local task_id
	local project_root
	local commit_epoch
	task_id="$1"
	project_root="$2"
	commit_epoch="$3"

	local project_id
	project_id=$(find_opencode_project_id "$project_root") || true

	local session_id=""
	local session_title=""
	local parent_session=""
	local search_session=""

	if [[ -n "$project_id" && -n "$commit_epoch" ]]; then
		local session_info
		session_info=$(find_session_by_timestamp "$project_id" "$commit_epoch") || true
		if [[ -n "$session_info" ]]; then
			session_id=$(echo "$session_info" | cut -d'|' -f1)
			session_title=$(echo "$session_info" | cut -d'|' -f2)
			local parent_id
			parent_id=$(echo "$session_info" | cut -d'|' -f3)

			if [[ -n "$parent_id" ]]; then
				parent_session=$(find_parent_session "$session_id") || true
			fi

			log_info "$task_id: session $session_id '$session_title'"
		fi
	fi

	# If this was a subagent commit session, search the parent instead
	search_session="$session_id"
	if [[ "$session_title" == *"subagent"* && -n "$parent_session" ]]; then
		search_session=$(echo "$parent_session" | cut -d'|' -f1)
		local p_title
		p_title=$(echo "$parent_session" | cut -d'|' -f2)
		log_info "$task_id: searching parent session '$p_title'"
	fi

	echo "SESSION_ID=$session_id"
	echo "SESSION_TITLE=$session_title"
	echo "PARENT_SESSION=$parent_session"
	echo "SEARCH_SESSION=$search_session"
	return 0
}

# Extract the indented block for task_id from a TODO.md file.
# Writes block content to stdout (multi-line safe).
_extract_todo_block() {
	local task_id
	local todo_file
	task_id="$1"
	todo_file="$2"

	BRIEF_TASK_ID="$task_id" BRIEF_TODO_FILE="$todo_file" python3 -c "
import re, os
task_id = os.environ['BRIEF_TASK_ID']
todo_file = os.environ['BRIEF_TODO_FILE']
lines = open(todo_file).readlines()
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
" 2>/dev/null
	return 0
}

# Extract task metadata from TODO.md: task line, task block, rebase note.
# Outputs simple KEY=VALUE lines; TASK_BLOCK written to a temp file (path in TASK_BLOCK_FILE).
_resolve_task_metadata() {
	local task_id
	local project_root
	task_id="$1"
	project_root="$2"

	local task_line=""
	task_line=$(grep -E "^\s*- \[.\] ${task_id} " "$project_root/TODO.md" 2>/dev/null | head -1) || true

	local task_title=""
	task_title=$(echo "$task_line" | sed -E 's/^.*\] t[0-9]+(\.[0-9]+)* //' | sed -E 's/ #.*//' | sed -E 's/ ~//')

	local rebase_note=""
	rebase_note=$(echo "$task_line" | grep -oE '<!-- REBASE:[^>]+-->' | sed 's/<!-- REBASE: //;s/ -->//' || true)

	# Write multi-line task_block to a temp file to avoid sentinel parsing in callers
	local block_file
	block_file=$(mktemp)
	_extract_todo_block "$task_id" "$project_root/TODO.md" >"$block_file" 2>/dev/null || true

	printf 'TASK_TITLE=%s\n' "$task_title"
	printf 'REBASE_NOTE=%s\n' "$rebase_note"
	printf 'TASK_LINE=%s\n' "$task_line"
	printf 'TASK_BLOCK_FILE=%s\n' "$block_file"
	return 0
}

# Derive session_origin and created_by strings from resolved session/commit/supervisor data.
# Args: session_id session_title parent_session supervisor_info commit_author task_id
# Outputs: SESSION_ORIGIN=... CREATED_BY=... SUP_ID=...
_derive_attribution() {
	local session_id session_title parent_session supervisor_info commit_author task_id
	session_id="$1"
	session_title="$2"
	parent_session="$3"
	supervisor_info="$4"
	commit_author="$5"
	task_id="$6"

	local session_origin="unknown"
	local sup_id=""
	if [[ -n "$supervisor_info" ]]; then
		sup_id=$(echo "$supervisor_info" | cut -d'|' -f1)
	fi

	if [[ -n "$session_id" ]]; then
		if [[ -n "$parent_session" ]]; then
			local p_id p_title
			p_id=$(echo "$parent_session" | cut -d'|' -f1)
			p_title=$(echo "$parent_session" | cut -d'|' -f2)
			session_origin="opencode:${p_id} '${p_title}' (committed via subagent ${session_id})"
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

	local created_by="ai-interactive"
	if [[ -n "$sup_id" && "$sup_id" == "$task_id" ]]; then
		created_by="ai-supervisor"
	elif [[ "$commit_author" != "marcusquinn" && "$commit_author" != "GitHub Actions" ]]; then
		created_by="human ($commit_author)"
	fi

	printf 'SESSION_ORIGIN=%s\n' "$session_origin"
	printf 'CREATED_BY=%s\n' "$created_by"
	printf 'SUP_ID=%s\n' "$sup_id"
	return 0
}

# Write the brief markdown file given all resolved metadata.
_write_brief_file() {
	local output_file task_id task_title commit commit_date commit_msg
	local session_origin created_by parent_task
	local best_block context_block task_block rebase_note supervisor_info sup_id
	output_file="$1"
	task_id="$2"
	task_title="$3"
	commit="$4"
	commit_date="$5"
	commit_msg="$6"
	session_origin="$7"
	created_by="$8"
	parent_task="$9"
	best_block="${10}"
	context_block="${11}"
	task_block="${12}"
	rebase_note="${13}"
	supervisor_info="${14}"
	sup_id="${15}"

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

	return 0
}

# Extract context_block from session context output and optionally enrich session_origin.
# Args: context session_origin
# Outputs: CONTEXT_BLOCK=... SESSION_ORIGIN=...
_enrich_context() {
	local context
	local session_origin
	context="$1"
	session_origin="$2"

	local context_block=""
	if [[ "$context" != "NO_CONTEXT_FOUND" ]]; then
		local msg_title
		msg_title=$(echo "$context" | grep '^MESSAGE_TITLE=' | head -1 | sed 's/MESSAGE_TITLE=//')
		context_block=$(echo "$context" | sed -n '/^TASK_BLOCK_START$/,/^TASK_BLOCK_END$/p' | grep -v 'TASK_BLOCK_')
		if [[ -n "$msg_title" ]]; then
			session_origin="${session_origin} — message: '${msg_title}'"
		fi
	fi

	printf 'SESSION_ORIGIN=%s\n' "$session_origin"
	printf 'CONTEXT_BLOCK_START\n%s\nCONTEXT_BLOCK_END\n' "$context_block"
	return 0
}

generate_brief() {
	local task_id
	local project_root
	local output_file
	task_id="$1"
	project_root="$2"
	output_file="$project_root/todo/tasks/${task_id}-brief.md"

	validate_task_id "$task_id" || return 1
	mkdir -p "$project_root/todo/tasks"

	# Step 1: Resolve commit
	local commit="" commit_date="" commit_author="" commit_msg="" commit_epoch=""
	while IFS='=' read -r key value; do
		case "$key" in
		COMMIT) commit="$value" ;;
		COMMIT_DATE) commit_date="$value" ;;
		COMMIT_AUTHOR) commit_author="$value" ;;
		COMMIT_MSG) commit_msg="$value" ;;
		COMMIT_EPOCH) commit_epoch="$value" ;;
		esac
	done <<<"$(_resolve_commit_info "$task_id" "$project_root")" || return 1

	log_info "$task_id: commit $commit ($commit_date) by $commit_author"

	# Step 2: Resolve session
	local session_id="" session_title="" parent_session="" search_session=""
	while IFS='=' read -r key value; do
		case "$key" in
		SESSION_ID) session_id="$value" ;;
		SESSION_TITLE) session_title="$value" ;;
		PARENT_SESSION) parent_session="$value" ;;
		SEARCH_SESSION) search_session="$value" ;;
		esac
	done <<<"$(_resolve_session_info "$task_id" "$project_root" "$commit_epoch")"

	# Step 3: Extract conversation context
	local context="NO_CONTEXT_FOUND"
	if [[ -n "$search_session" ]]; then
		context=$(extract_session_context "$search_session" "$task_id") || true
	fi

	# Step 4: Supervisor DB
	local supervisor_info=""
	supervisor_info=$(find_supervisor_context "$task_id") || true

	# Step 5: Task metadata from TODO.md
	local task_title="" rebase_note="" task_line="" task_block_file=""
	while IFS='=' read -r key value; do
		case "$key" in
		TASK_TITLE) task_title="$value" ;;
		REBASE_NOTE) rebase_note="$value" ;;
		TASK_LINE) task_line="$value" ;;
		TASK_BLOCK_FILE) task_block_file="$value" ;;
		esac
	done <<<"$(_resolve_task_metadata "$task_id" "$project_root")"
	local task_block=""
	[[ -f "$task_block_file" ]] && task_block=$(cat "$task_block_file") && rm -f "$task_block_file"

	# Step 6: Derive session_origin and created_by
	local session_origin="" created_by="" sup_id=""
	while IFS='=' read -r key value; do
		case "$key" in
		SESSION_ORIGIN) session_origin="$value" ;;
		CREATED_BY) created_by="$value" ;;
		SUP_ID) sup_id="$value" ;;
		esac
	done <<<"$(_derive_attribution "$session_id" "$session_title" "$parent_session" \
		"$supervisor_info" "$commit_author" "$task_id")"

	# Step 7: Extract context block and enrich session_origin
	local context_block="" _in_ctx=0
	while IFS= read -r line; do
		case "$line" in
		SESSION_ORIGIN=*) session_origin="${line#SESSION_ORIGIN=}" ;;
		CONTEXT_BLOCK_START) _in_ctx=1 ;;
		CONTEXT_BLOCK_END) _in_ctx=0 ;;
		*)
			if [[ "$_in_ctx" -eq 1 ]]; then
				context_block="${context_block:+${context_block}$'\n'}${line}"
			fi
			;;
		esac
	done <<<"$(_enrich_context "$context" "$session_origin")"

	local parent_task=""
	if echo "$task_id" | grep -qE '\.'; then
		parent_task=$(echo "$task_id" | sed -E 's/\.[0-9]+$//')
	fi

	local best_block="${context_block:-${task_block:-${task_line}}}"

	_write_brief_file "$output_file" "$task_id" "$task_title" "$commit" "$commit_date" \
		"$commit_msg" "$session_origin" "$created_by" "$parent_task" \
		"$best_block" "$context_block" "$task_block" "$rebase_note" \
		"$supervisor_info" "$sup_id"

	log_info "$task_id: brief written to $output_file"
	return 0
}

# --- Main ---

main() {
	local task_id
	local project_root
	task_id="${1:-}"
	project_root="${2:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

	if [[ -z "$task_id" ]]; then
		usage
	fi

	if [[ "$task_id" == "--all" ]]; then
		# Generate briefs for all open tasks without briefs
		local count
		count=0
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
		validate_task_id "$task_id" || exit 1
		generate_brief "$task_id" "$project_root"
	fi

	return 0
}

main "$@"
