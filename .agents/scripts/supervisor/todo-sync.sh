#!/usr/bin/env bash
# todo-sync.sh - Supervisor TODO.md synchronization functions
# Part of the AI DevOps Framework supervisor module

#######################################
# Commit and push TODO.md with pull-rebase retry
# Handles concurrent push conflicts from parallel workers
# Args: $1=repo_path $2=commit_message $3=max_retries (default 3)
#######################################
commit_and_push_todo() {
	local repo_path="$1"
	local commit_msg="$2"
	local max_retries="${3:-3}"

	if git -C "$repo_path" diff --quiet -- TODO.md 2>>"$SUPERVISOR_LOG"; then
		log_info "No changes to commit (TODO.md unchanged)"
		return 0
	fi

	git -C "$repo_path" add TODO.md

	local attempt=0
	while [[ "$attempt" -lt "$max_retries" ]]; do
		attempt=$((attempt + 1))

		# Pull-rebase to incorporate any concurrent TODO.md pushes
		if ! git -C "$repo_path" pull --rebase --autostash 2>>"$SUPERVISOR_LOG"; then
			log_warn "Pull-rebase failed (attempt $attempt/$max_retries)"
			# Abort rebase if in progress and retry
			git -C "$repo_path" rebase --abort 2>>"$SUPERVISOR_LOG" || true
			sleep "$attempt"
			continue
		fi

		# Re-stage TODO.md (rebase may have resolved it)
		if ! git -C "$repo_path" diff --quiet -- TODO.md 2>>"$SUPERVISOR_LOG"; then
			git -C "$repo_path" add TODO.md
		fi

		# Check if our change survived the rebase (may have been applied by another worker)
		if git -C "$repo_path" diff --cached --quiet -- TODO.md 2>>"$SUPERVISOR_LOG"; then
			log_info "TODO.md change already applied (likely by another worker)"
			return 0
		fi

		# Commit
		if ! git -C "$repo_path" commit -m "$commit_msg" -- TODO.md 2>>"$SUPERVISOR_LOG"; then
			log_warn "Commit failed (attempt $attempt/$max_retries)"
			sleep "$attempt"
			continue
		fi

		# Push
		if git -C "$repo_path" push 2>>"$SUPERVISOR_LOG"; then
			log_success "Committed and pushed TODO.md update"
			return 0
		fi

		log_warn "Push failed (attempt $attempt/$max_retries) - will pull-rebase and retry"
		sleep "$attempt"
	done

	log_error "Failed to push TODO.md after $max_retries attempts"
	return 1
}

#######################################
# Populate VERIFY.md queue after PR merge (t180.2)
# Extracts changed files from the PR and generates check: directives
# based on file types (shellcheck for .sh, file-exists for new files, etc.)
# Appends a new entry to the VERIFY-QUEUE in todo/VERIFY.md
#######################################
populate_verify_queue() {
	local task_id="$1"
	local pr_url="${2:-}"
	local repo="${3:-}"

	if [[ -z "$repo" ]]; then
		log_warn "populate_verify_queue: no repo for $task_id"
		return 1
	fi

	local verify_file="$repo/todo/VERIFY.md"
	if [[ ! -f "$verify_file" ]]; then
		log_info "No VERIFY.md at $verify_file — skipping verify queue population"
		return 0
	fi

	# Extract PR number and repo slug (t232)
	local parsed_populate pr_number repo_slug
	parsed_populate=$(parse_pr_url "$pr_url") || parsed_populate=""
	if [[ -z "$parsed_populate" ]]; then
		log_warn "populate_verify_queue: cannot parse PR URL for $task_id: $pr_url"
		return 1
	fi
	repo_slug="${parsed_populate%%|*}"
	pr_number="${parsed_populate##*|}"

	# Check if this task already has a verify entry (idempotency)
	if grep -q "^- \[.\] v[0-9]* $task_id " "$verify_file" 2>/dev/null; then
		log_info "Verify entry already exists for $task_id in VERIFY.md"
		return 0
	fi

	# Get changed files from PR
	local changed_files
	if ! changed_files=$(gh pr view "$pr_number" --repo "$repo_slug" --json files --jq '.files[].path' 2>>"$SUPERVISOR_LOG"); then
		log_warn "populate_verify_queue: failed to fetch PR files for $task_id (#$pr_number)"
		return 1
	fi

	if [[ -z "$changed_files" ]]; then
		log_info "No files changed in PR #$pr_number for $task_id"
		return 0
	fi

	# Filter to substantive files (skip TODO.md, planning files)
	local substantive_files
	substantive_files=$(echo "$changed_files" | grep -vE '^(TODO\.md$|todo/)' || true)

	if [[ -z "$substantive_files" ]]; then
		log_info "No substantive files in PR #$pr_number for $task_id — skipping verify"
		return 0
	fi

	# Get task description from DB
	local task_desc
	task_desc=$(db "$SUPERVISOR_DB" "SELECT description FROM tasks WHERE id = '$(sql_escape "$task_id")';" 2>/dev/null || echo "$task_id")
	# Truncate long descriptions
	if [[ ${#task_desc} -gt 60 ]]; then
		task_desc="${task_desc:0:57}..."
	fi

	# Determine next verify ID
	local last_vnum
	last_vnum=$(grep -oE 'v[0-9]+' "$verify_file" | grep -oE '[0-9]+' | sort -n | tail -1 || echo "0")
	last_vnum=$((10#$last_vnum))
	local next_vnum=$((last_vnum + 1))
	local verify_id
	verify_id=$(printf "v%03d" "$next_vnum")

	local today
	today=$(date +%Y-%m-%d)

	# Build the verify entry
	local entry=""
	entry+="- [ ] $verify_id $task_id $task_desc | PR #$pr_number | merged:$today"
	entry+=$'\n'
	entry+="  files: $(echo "$substantive_files" | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g')"

	# Generate check directives based on file types
	local checks=""
	while IFS= read -r file; do
		[[ -z "$file" ]] && continue
		case "$file" in
		*.sh)
			checks+=$'\n'"  check: shellcheck $file"
			checks+=$'\n'"  check: file-exists $file"
			;;
		*.md)
			checks+=$'\n'"  check: file-exists $file"
			;;
		*.toon)
			checks+=$'\n'"  check: file-exists $file"
			;;
		*.yml | *.yaml)
			checks+=$'\n'"  check: file-exists $file"
			;;
		*.json)
			checks+=$'\n'"  check: file-exists $file"
			;;
		*)
			checks+=$'\n'"  check: file-exists $file"
			;;
		esac
	done <<<"$substantive_files"

	# Also add subagent-index check if any .md files in .agents/ were changed
	if echo "$substantive_files" | grep -qE '\.agents/.*\.md$'; then
		local base_names
		base_names=$(echo "$substantive_files" | grep -E '\.agents/.*\.md$' | xargs -I{} basename {} .md || true)
		while IFS= read -r bname; do
			[[ -z "$bname" ]] && continue
			# Only check for subagent-index entries for tool/service/workflow files
			if echo "$substantive_files" | grep -qE "\.agents/(tools|services|workflows)/.*${bname}\.md$"; then
				checks+=$'\n'"  check: rg \"$bname\" .agents/subagent-index.toon"
			fi
		done <<<"$base_names"
	fi

	entry+="$checks"

	# Append to VERIFY.md before the end marker
	if grep -q '<!-- VERIFY-QUEUE-END -->' "$verify_file"; then
		# Insert before the end marker
		local temp_file
		temp_file=$(mktemp)
		_save_cleanup_scope
		trap '_run_cleanups' RETURN
		push_cleanup "rm -f '${temp_file}'"
		awk -v entry="$entry" '
            /<!-- VERIFY-QUEUE-END -->/ {
                print entry
                print ""
            }
            { print }
        ' "$verify_file" >"$temp_file"
		mv "$temp_file" "$verify_file"
	else
		# No end marker — append to end of file
		echo "" >>"$verify_file"
		echo "$entry" >>"$verify_file"
	fi

	log_success "Added verify entry $verify_id for $task_id to VERIFY.md"
	return 0
}

#######################################
# Mark a verify entry as passed [x] or failed [!] in VERIFY.md (t180.3)
#######################################
mark_verify_entry() {
	local verify_file="$1"
	local task_id="$2"
	local result="$3"
	local today="${4:-$(date +%Y-%m-%d)}"
	local reason="${5:-}"

	if [[ "$result" == "pass" ]]; then
		# Mark [x] and add verified:date
		sed -i.bak "s/^- \[ \] \(v[0-9]* $task_id .*\)/- [x] \1 verified:$today/" "$verify_file"
	else
		# Mark [!] and add failed:date reason:description
		local escaped_reason
		escaped_reason=$(echo "$reason" | sed 's/[&/\]/\\&/g' | head -c 200)
		sed -i.bak "s/^- \[ \] \(v[0-9]* $task_id .*\)/- [!] \1 failed:$today reason:$escaped_reason/" "$verify_file"
	fi
	rm -f "${verify_file}.bak"

	return 0
}

#######################################
# Process verification queue — run checks for deployed tasks (t180.3)
# Scans VERIFY.md for pending entries, runs checks, updates states
# Called from pulse Phase 6
#######################################
process_verify_queue() {
	local batch_id="${1:-}"

	ensure_db

	# Find deployed tasks that need verification
	local deployed_tasks
	local where_clause="t.status = 'deployed'"
	if [[ -n "$batch_id" ]]; then
		where_clause="$where_clause AND EXISTS (SELECT 1 FROM batch_tasks bt WHERE bt.task_id = t.id AND bt.batch_id = '$(sql_escape "$batch_id")')"
	fi

	deployed_tasks=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT t.id, t.repo, t.pr_url FROM tasks t
        WHERE $where_clause
        ORDER BY t.updated_at ASC;
    ")

	if [[ -z "$deployed_tasks" ]]; then
		return 0
	fi

	local verified_count=0
	local failed_count=0

	while IFS='|' read -r tid trepo _tpr; do
		[[ -z "$tid" ]] && continue

		local verify_file="$trepo/todo/VERIFY.md"
		if [[ ! -f "$verify_file" ]]; then
			continue
		fi

		# Check if there's a pending verify entry for this task
		if ! grep -q "^- \[ \] v[0-9]* $tid " "$verify_file" 2>/dev/null; then
			continue
		fi

		log_info "  $tid: running verification checks"
		cmd_transition "$tid" "verifying" 2>>"$SUPERVISOR_LOG" || {
			log_warn "  $tid: failed to transition to verifying"
			continue
		}

		if run_verify_checks "$tid" "$trepo"; then
			cmd_transition "$tid" "verified" 2>>"$SUPERVISOR_LOG" || true
			verified_count=$((verified_count + 1))
			log_success "  $tid: VERIFIED"
		else
			cmd_transition "$tid" "verify_failed" 2>>"$SUPERVISOR_LOG" || true
			failed_count=$((failed_count + 1))
			log_warn "  $tid: VERIFY FAILED"
			send_task_notification "$tid" "verify_failed" "Post-merge verification failed" 2>>"$SUPERVISOR_LOG" || true
		fi
	done <<<"$deployed_tasks"

	if [[ $((verified_count + failed_count)) -gt 0 ]]; then
		log_info "Verification: $verified_count passed, $failed_count failed"
	fi

	return 0
}

#######################################
# Commit and push VERIFY.md changes after verification (t180.3)
#######################################
commit_verify_changes() {
	local repo="$1"
	local task_id="$2"
	local result="$3"

	local verify_file="$repo/todo/VERIFY.md"
	if [[ ! -f "$verify_file" ]]; then
		return 0
	fi

	# Check if there are changes to commit
	if ! git -C "$repo" diff --quiet -- "todo/VERIFY.md" 2>/dev/null; then
		local msg="chore: mark $task_id verification $result in VERIFY.md [skip ci]"
		git -C "$repo" add "todo/VERIFY.md" 2>>"$SUPERVISOR_LOG" || return 1
		git -C "$repo" commit -m "$msg" 2>>"$SUPERVISOR_LOG" || return 1
		git -C "$repo" push origin main 2>>"$SUPERVISOR_LOG" || return 1
		log_info "Committed VERIFY.md update for $task_id ($result)"
	fi

	return 0
}

#######################################
# Update TODO.md when a task completes
# Marks the task checkbox as [x], adds completed:YYYY-MM-DD
# Then commits and pushes the change
# Guard (t163): requires verified deliverables before marking [x]
#######################################
update_todo_on_complete() {
	local task_id="$1"

	ensure_db

	local escaped_id
	escaped_id=$(sql_escape "$task_id")
	local task_row
	task_row=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT repo, description, pr_url FROM tasks WHERE id = '$escaped_id';
    ")

	if [[ -z "$task_row" ]]; then
		log_error "Task not found: $task_id"
		return 1
	fi

	local trepo tdesc tpr_url
	IFS='|' read -r trepo tdesc tpr_url <<<"$task_row"

	# Verify deliverables before marking complete (t163.4)
	if ! verify_task_deliverables "$task_id" "$tpr_url" "$trepo"; then
		log_warn "Task $task_id failed deliverable verification - NOT marking [x] in TODO.md"
		log_warn "  To manually verify: add 'verified:$(date +%Y-%m-%d)' to the task line"
		return 1
	fi

	local todo_file="$trepo/TODO.md"
	if [[ ! -f "$todo_file" ]]; then
		log_warn "TODO.md not found at $todo_file"
		return 1
	fi

	# t1003: Guard against marking parent tasks complete when subtasks are still open.
	# Any task with subtasks (indented children OR explicit tNNN.M IDs) should only be
	# marked [x] when ALL its subtasks are [x]. This prevents workers from prematurely
	# completing parents, regardless of #plan tag.
	local task_line
	task_line=$(grep -E "^[[:space:]]*- \[[ x-]\] ${task_id}( |$)" "$todo_file" | head -1 || true)
	if [[ -n "$task_line" ]]; then
		# Check for explicit subtask IDs (e.g., t123.1, t123.2 are children of t123)
		local explicit_subtasks
		explicit_subtasks=$(grep -E "^[[:space:]]*- \[ \] ${task_id}\.[0-9]+( |$)" "$todo_file" || true)

		if [[ -n "$explicit_subtasks" ]]; then
			local open_count
			open_count=$(echo "$explicit_subtasks" | wc -l | tr -d ' ')
			log_warn "Task $task_id has $open_count open subtask(s) by ID — NOT marking [x]"
			log_warn "  Parent tasks should only be completed when all subtasks are done"
			return 1
		fi

		# Get the indentation level of this task
		local task_indent
		task_indent=$(echo "$task_line" | sed -E 's/^([[:space:]]*).*/\1/' | wc -c)
		task_indent=$((task_indent - 1)) # wc -c counts newline

		# Check for open subtasks (lines indented deeper with [ ])
		local open_subtasks
		open_subtasks=$(awk -v tid="$task_id" -v tindent="$task_indent" '
            BEGIN { found=0 }
            /- \[[ x-]\] '"$task_id"'( |$)/ { found=1; next }
            found && /^[[:space:]]*- \[/ {
                # Count leading spaces
                match($0, /^[[:space:]]*/);
                line_indent = RLENGTH;
                if (line_indent > tindent) {
                    if ($0 ~ /- \[ \]/) { print $0 }
                } else { found=0 }
            }
            found && /^[[:space:]]*$/ { next }
            found && !/^[[:space:]]*- / && !/^[[:space:]]*$/ { found=0 }
        ' "$todo_file")

		if [[ -n "$open_subtasks" ]]; then
			local open_count
			open_count=$(echo "$open_subtasks" | wc -l | tr -d ' ')
			log_warn "Task $task_id has $open_count open subtask(s) by indentation — NOT marking [x]"
			log_warn "  Parent tasks should only be completed when all subtasks are done"
			return 1
		fi
	fi

	local today
	today=$(date +%Y-%m-%d)

	# Match the task line (open checkbox with task ID)
	# Handles both top-level and indented subtasks
	if ! grep -qE "^[[:space:]]*- \[ \] ${task_id}( |$)" "$todo_file"; then
		log_warn "Task $task_id not found as open in $todo_file (may already be completed)"
		return 0
	fi

	# Extract PR number from pr_url for proof-log (t1004)
	local pr_number=""
	if [[ -n "$tpr_url" && "$tpr_url" =~ /pull/([0-9]+) ]]; then
		pr_number="${BASH_REMATCH[1]}"
	fi

	# Mark as complete: [ ] -> [x], append pr:#NNN (if available) and completed:date
	# Use sed to match the line and transform it
	local proof_log=""
	if [[ -n "$pr_number" ]]; then
		proof_log=" pr:#${pr_number}"
	fi
	local sed_pattern="s/^([[:space:]]*- )\[ \] (${task_id} .*)$/\1[x] \2${proof_log} completed:${today}/"

	sed_inplace -E "$sed_pattern" "$todo_file"

	# Verify the change was made
	if ! grep -qE "^[[:space:]]*- \[x\] ${task_id} " "$todo_file"; then
		log_error "Failed to update TODO.md for $task_id"
		return 1
	fi

	log_success "Updated TODO.md: $task_id marked complete ($today)"

	local commit_msg="chore: mark $task_id complete in TODO.md"
	if [[ -n "$tpr_url" ]]; then
		commit_msg="chore: mark $task_id complete in TODO.md (${tpr_url})"
	fi
	commit_and_push_todo "$trepo" "$commit_msg"
	return $?
}

#######################################
# Generate a VERIFY.md entry for a deployed task (t180.4)
# Auto-creates check directives based on PR files:
#   - .sh files: shellcheck + bash -n + file-exists
#   - .md files: file-exists
#   - test files: bash <test>
#   - other: file-exists
# Appends entry before <!-- VERIFY-QUEUE-END --> marker
# $1: task_id
#######################################
generate_verify_entry() {
	local task_id="$1"

	ensure_db

	local escaped_id
	escaped_id=$(sql_escape "$task_id")
	local task_row
	task_row=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT repo, description, pr_url FROM tasks WHERE id = '$escaped_id';
    ")

	if [[ -z "$task_row" ]]; then
		log_warn "generate_verify_entry: task not found: $task_id"
		return 1
	fi

	local trepo tdesc tpr_url
	IFS='|' read -r trepo tdesc tpr_url <<<"$task_row"

	local verify_file="$trepo/todo/VERIFY.md"
	if [[ ! -f "$verify_file" ]]; then
		log_warn "generate_verify_entry: VERIFY.md not found at $verify_file"
		return 1
	fi

	# Check if entry already exists for this task
	local task_id_escaped
	task_id_escaped=$(printf '%s' "$task_id" | sed 's/\./\\./g')
	if grep -qE "^- \[.\] v[0-9]+ ${task_id_escaped} " "$verify_file"; then
		log_info "generate_verify_entry: entry already exists for $task_id"
		return 0
	fi

	# Get next vNNN number
	local last_v
	last_v=$(grep -oE '^- \[.\] v([0-9]+)' "$verify_file" | grep -oE '[0-9]+' | sort -n | tail -1 || echo "0")
	last_v=$((10#$last_v))
	local next_v=$((last_v + 1))
	local vid
	vid=$(printf "v%03d" "$next_v")

	# Extract PR number
	local pr_number=""
	if [[ "$tpr_url" =~ /pull/([0-9]+) ]]; then
		pr_number="${BASH_REMATCH[1]}"
	fi

	local today
	today=$(date +%Y-%m-%d)

	# Get files changed in PR (requires gh CLI)
	local files_list=""
	local -a check_lines=()

	if [[ -n "$pr_number" ]] && command -v gh &>/dev/null && check_gh_auth; then
		local repo_slug=""
		repo_slug=$(detect_repo_slug "$trepo" 2>/dev/null || echo "")
		if [[ -n "$repo_slug" ]]; then
			files_list=$(gh pr view "$pr_number" --repo "$repo_slug" --json files --jq '.files[].path' 2>/dev/null | tr '\n' ', ' | sed 's/,$//')

			# Generate check directives based on file types
			while IFS= read -r fpath; do
				[[ -z "$fpath" ]] && continue
				case "$fpath" in
				tests/*.sh | test-*.sh)
					check_lines+=("  check: bash $fpath")
					;;
				*.sh)
					check_lines+=("  check: file-exists $fpath")
					check_lines+=("  check: shellcheck $fpath")
					check_lines+=("  check: bash -n $fpath")
					;;
				*.md)
					check_lines+=("  check: file-exists $fpath")
					;;
				*)
					check_lines+=("  check: file-exists $fpath")
					;;
				esac
			done < <(gh pr view "$pr_number" --repo "$repo_slug" --json files --jq '.files[].path' 2>/dev/null)
		fi
	fi

	# Fallback: if no checks generated, add basic file-exists for PR
	if [[ ${#check_lines[@]} -eq 0 && -n "$pr_number" ]]; then
		check_lines+=("  check: rg \"$task_id\" $trepo/TODO.md")
	fi

	# Build the entry
	local entry_header="- [ ] $vid $task_id ${tdesc%% *} | PR #${pr_number:-unknown} | merged:$today"
	local entry_body=""
	if [[ -n "$files_list" ]]; then
		entry_body+="  files: $files_list"$'\n'
	fi
	for cl in "${check_lines[@]}"; do
		entry_body+="$cl"$'\n'
	done

	# Insert before <!-- VERIFY-QUEUE-END -->
	local marker="<!-- VERIFY-QUEUE-END -->"
	if ! grep -q "$marker" "$verify_file"; then
		log_warn "generate_verify_entry: VERIFY-QUEUE-END marker not found"
		return 1
	fi

	# Build full entry text
	local full_entry
	full_entry=$(printf '%s\n%s\n' "$entry_header" "$entry_body")

	# Insert before marker using temp file (portable across macOS/Linux)
	local tmp_file
	tmp_file=$(mktemp)
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "rm -f '${tmp_file}'"
	awk -v entry="$full_entry" -v mark="$marker" '{
        if (index($0, mark) > 0) { print entry; }
        print;
    }' "$verify_file" >"$tmp_file" && mv "$tmp_file" "$verify_file"

	log_success "Generated verify entry $vid for $task_id (PR #${pr_number:-unknown})"

	# Commit and push
	commit_and_push_todo "$trepo" "chore: add verify entry $vid for $task_id" 2>>"$SUPERVISOR_LOG" || true

	return 0
}

#######################################
# Update TODO.md when a task is blocked or failed
# Adds Notes line with blocked reason
# Then commits and pushes the change
# t296: Also posts a comment to GitHub issue if ref:GH# exists
#######################################
update_todo_on_blocked() {
	local task_id="$1"
	local reason="${2:-unknown}"

	ensure_db

	local escaped_id
	escaped_id=$(sql_escape "$task_id")
	local trepo
	trepo=$(db "$SUPERVISOR_DB" "SELECT repo FROM tasks WHERE id = '$escaped_id';")

	if [[ -z "$trepo" ]]; then
		log_error "Task not found: $task_id"
		return 1
	fi

	local todo_file="$trepo/TODO.md"
	if [[ ! -f "$todo_file" ]]; then
		log_warn "TODO.md not found at $todo_file"
		return 1
	fi

	# Find the task line number
	local line_num
	line_num=$(grep -nE "^[[:space:]]*- \[ \] ${task_id}( |$)" "$todo_file" | head -1 | cut -d: -f1)

	if [[ -z "$line_num" ]]; then
		log_warn "Task $task_id not found as open in $todo_file"
		return 0
	fi

	# Detect indentation of the task line for proper Notes alignment
	local task_line
	task_line=$(sed -n "${line_num}p" "$todo_file")
	local indent=""
	indent=$(echo "$task_line" | sed -E 's/^([[:space:]]*).*/\1/')

	# Check if a Notes line already exists below the task
	local next_line_num=$((line_num + 1))
	local next_line
	next_line=$(sed -n "${next_line_num}p" "$todo_file" 2>/dev/null || echo "")

	# Sanitize reason for safe insertion (escape special sed chars)
	local safe_reason
	safe_reason=$(echo "$reason" | sed 's/[&/\]/\\&/g' | head -c 200)

	if echo "$next_line" | grep -qE "^[[:space:]]*- Notes:"; then
		# Append to existing Notes line
		local append_text=" BLOCKED: ${safe_reason}"
		sed_inplace "${next_line_num}s/$/${append_text}/" "$todo_file"
	else
		# Insert a new Notes line after the task
		local notes_line="${indent}  - Notes: BLOCKED by supervisor: ${safe_reason}"
		sed_append_after "$line_num" "$notes_line" "$todo_file"
	fi

	log_success "Updated TODO.md: $task_id marked blocked ($reason)"

	# t296: Post comment to GitHub issue if ref:GH# exists
	post_blocked_comment_to_github "$task_id" "$reason" "$trepo" 2>>"${SUPERVISOR_LOG:-/dev/null}" || true

	commit_and_push_todo "$trepo" "chore: mark $task_id blocked in TODO.md"
	return $?
}

#######################################
# Command: update-todo - manually trigger TODO.md update for a task
#######################################
cmd_update_todo() {
	local task_id=""

	if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
		task_id="$1"
		shift
	fi

	if [[ -z "$task_id" ]]; then
		log_error "Usage: supervisor-helper.sh update-todo <task_id>"
		return 1
	fi

	ensure_db

	local escaped_id
	escaped_id=$(sql_escape "$task_id")
	local tstatus
	tstatus=$(db "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$escaped_id';")

	if [[ -z "$tstatus" ]]; then
		log_error "Task not found: $task_id"
		return 1
	fi

	case "$tstatus" in
	complete | deployed | merged | verified)
		update_todo_on_complete "$task_id"
		;;
	blocked)
		local terror
		terror=$(db "$SUPERVISOR_DB" "SELECT error FROM tasks WHERE id = '$escaped_id';")
		update_todo_on_blocked "$task_id" "${terror:-blocked by supervisor}"
		;;
	failed)
		local terror
		terror=$(db "$SUPERVISOR_DB" "SELECT error FROM tasks WHERE id = '$escaped_id';")
		update_todo_on_blocked "$task_id" "FAILED: ${terror:-unknown}"
		;;
	*)
		log_warn "Task $task_id is in '$tstatus' state - TODO update only applies to complete/deployed/merged/blocked/failed tasks"
		return 1
		;;
	esac

	return 0
}

#######################################
# Command: reconcile-todo - bulk-update TODO.md for all completed/deployed tasks
# Finds tasks in supervisor DB that are complete/deployed/merged but still
# show as open [ ] in TODO.md, and updates them.
# Handles the case where concurrent push failures left TODO.md stale.
#######################################
cmd_reconcile_todo() {
	local repo_path=""
	local dry_run="false"
	local batch_id=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--repo)
			repo_path="$2"
			shift 2
			;;
		--batch)
			batch_id="$2"
			shift 2
			;;
		--dry-run)
			dry_run="true"
			shift
			;;
		*) shift ;;
		esac
	done

	ensure_db

	# Find completed/deployed/merged/verified tasks
	local where_clause="t.status IN ('complete', 'deployed', 'merged', 'verified')"
	if [[ -n "$batch_id" ]]; then
		local escaped_batch
		escaped_batch=$(sql_escape "$batch_id")
		where_clause="$where_clause AND EXISTS (SELECT 1 FROM batch_tasks bt WHERE bt.task_id = t.id AND bt.batch_id = '$escaped_batch')"
	fi

	local completed_tasks
	completed_tasks=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT t.id, t.repo, t.pr_url FROM tasks t
        WHERE $where_clause
        ORDER BY t.id;
    ")

	if [[ -z "$completed_tasks" ]]; then
		log_info "No completed tasks found in supervisor DB"
		return 0
	fi

	local stale_count=0
	local updated_count=0
	local stale_tasks=""

	while IFS='|' read -r tid trepo tpr_url; do
		[[ -z "$tid" ]] && continue

		# Use provided repo or task's repo
		local check_repo="${repo_path:-$trepo}"
		local todo_file="$check_repo/TODO.md"

		if [[ ! -f "$todo_file" ]]; then
			continue
		fi

		# Check if task is still open in TODO.md
		if grep -qE "^[[:space:]]*- \[ \] ${tid}( |$)" "$todo_file"; then
			stale_count=$((stale_count + 1))
			stale_tasks="${stale_tasks}${stale_tasks:+, }${tid}"

			if [[ "$dry_run" == "true" ]]; then
				log_warn "[dry-run] $tid: deployed in DB but open in TODO.md"
			else
				log_info "Reconciling $tid..."

				# t260: Attempt PR discovery if pr_url is missing before calling update_todo_on_complete
				if [[ -z "$tpr_url" || "$tpr_url" == "no_pr" || "$tpr_url" == "task_only" || "$tpr_url" == "task_obsolete" ]]; then
					log_verbose "  $tid: Attempting PR discovery before reconciliation"
					link_pr_to_task "$tid" --caller "reconcile_todo" 2>>"${SUPERVISOR_LOG:-/dev/null}" || true
				fi

				if update_todo_on_complete "$tid"; then
					updated_count=$((updated_count + 1))
				else
					log_warn "Failed to reconcile $tid"
				fi
			fi
		fi
	done <<<"$completed_tasks"

	if [[ "$stale_count" -eq 0 ]]; then
		log_success "TODO.md is in sync with supervisor DB (no stale tasks)"
	elif [[ "$dry_run" == "true" ]]; then
		log_warn "$stale_count stale task(s) found: $stale_tasks"
		log_info "Run without --dry-run to fix"
	else
		log_success "Reconciled $updated_count/$stale_count stale tasks"
		if [[ "$updated_count" -lt "$stale_count" ]]; then
			log_warn "$((stale_count - updated_count)) task(s) could not be reconciled"
		fi
	fi

	return 0
}

#######################################
# Phase 0.5b: Deduplicate task IDs in TODO.md (t319.4)
# Scans TODO.md for duplicate task IDs on multiple open `- [ ]` lines.
# Keeps the first occurrence, renames duplicates to t(max+1).
# Commits and pushes changes if any duplicates were resolved.
# Arguments:
#   $1 - repo path containing TODO.md
# Returns:
#   0 on success (including no duplicates found), 1 on error
#######################################
dedup_todo_task_ids() {
	local repo_path="$1"
	local todo_file="$repo_path/TODO.md"

	if [[ ! -f "$todo_file" ]]; then
		log_verbose "dedup_todo_task_ids: no TODO.md at $todo_file"
		return 0
	fi

	# Extract all open task IDs from lines matching: - [ ] tNNN ...
	# Captures: line_number|full_task_id (e.g. "42|t319" or "43|t319.4")
	local task_lines
	task_lines=$(grep -nE '^[[:space:]]*- \[ \] t[0-9]+' "$todo_file" | while IFS=: read -r lnum line_content; do
		if [[ "$line_content" =~ ^[[:space:]]*-[[:space:]]\[[[:space:]]\][[:space:]](t[0-9]+(\.[0-9]+)*) ]]; then
			echo "${lnum}|${BASH_REMATCH[1]}"
		fi
	done)

	if [[ -z "$task_lines" ]]; then
		return 0
	fi

	# Find duplicate task IDs (same tNNN or tNNN.N appearing multiple times)
	local dup_ids
	dup_ids=$(echo "$task_lines" | awk -F'|' '{print $2}' | sort | uniq -d)

	if [[ -z "$dup_ids" ]]; then
		return 0
	fi

	log_warn "Phase 0.5b: Duplicate task IDs found in TODO.md, resolving..."

	# Find the current highest top-level task number for renaming
	local max_num
	max_num=$(grep -oE '(^|[[:space:]])t([0-9]+)' "$todo_file" | grep -oE '[0-9]+' | sort -n | tail -1 || echo "0")
	max_num=$((10#${max_num}))

	local changes_made=0

	while IFS= read -r dup_id; do
		[[ -z "$dup_id" ]] && continue

		log_warn "  Duplicate task ID: $dup_id"

		# Get all line numbers for this task ID (in order of appearance)
		local occurrences
		occurrences=$(echo "$task_lines" | awk -F'|' -v id="$dup_id" '$2 == id {print $1}')

		local first=true
		while IFS= read -r line_num; do
			[[ -z "$line_num" ]] && continue

			if [[ "$first" == "true" ]]; then
				log_info "    Keeping: line $line_num ($dup_id)"
				first=false
				continue
			fi

			# Allocate next available ID
			max_num=$((max_num + 1))
			local new_id="t${max_num}"

			# For subtask duplicates (tNNN.M), create new_id as tMAX.M
			if [[ "$dup_id" =~ ^t([0-9]+)\.([0-9]+)$ ]]; then
				local old_base="${BASH_REMATCH[1]}"
				local old_sub="${BASH_REMATCH[2]}"
				new_id="t${max_num}.${old_sub}"
				log_warn "    Renaming: line $line_num ($dup_id -> $new_id)"
				sed_inplace "${line_num}s/t${old_base}\.${old_sub}/${new_id}/" "$todo_file"
			else
				local old_num="${dup_id#t}"
				log_warn "    Renaming: line $line_num ($dup_id -> $new_id)"
				# Use word-boundary-like matching: tNNN followed by space or end-of-field
				sed_inplace -E "${line_num}s/t${old_num}( |$)/${new_id}\1/" "$todo_file"
			fi

			changes_made=$((changes_made + 1))
		done <<<"$occurrences"
	done <<<"$dup_ids"

	if [[ "$changes_made" -gt 0 ]]; then
		log_success "Phase 0.5b: Renamed $changes_made duplicate task ID(s) in TODO.md"
		commit_and_push_todo "$repo_path" "chore: dedup $changes_made duplicate task ID(s) in TODO.md (t319.4)"
	fi

	return 0
}

#######################################
# Command: reconcile-db-todo - bidirectional DB<->TODO.md reconciliation (t1001)
# Fills gaps not covered by cmd_reconcile_todo (Phase 7):
#   1. DB failed/blocked tasks with no annotation in TODO.md
#   2. Tasks marked [x] in TODO.md but DB still in non-terminal state
#   3. DB orphans: tasks in DB with no corresponding TODO.md entry
# Runs as Phase 7b in the supervisor pulse cycle.
# Arguments:
#   --repo <path>   - repo path (default: from DB or pwd)
#   --batch <id>    - filter to batch
#   --dry-run       - report only, don't modify
# Returns: 0 on success
#######################################
cmd_reconcile_db_todo() {
	local repo_path=""
	local dry_run="false"
	local batch_id=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--repo)
			repo_path="$2"
			shift 2
			;;
		--batch)
			batch_id="$2"
			shift 2
			;;
		--dry-run)
			dry_run="true"
			shift
			;;
		*) shift ;;
		esac
	done

	ensure_db

	# Determine repo path
	if [[ -z "$repo_path" ]]; then
		repo_path=$(db "$SUPERVISOR_DB" "SELECT DISTINCT repo FROM tasks LIMIT 1;" 2>/dev/null || echo "")
		if [[ -z "$repo_path" ]]; then
			repo_path="$(pwd)"
		fi
	fi

	local todo_file="$repo_path/TODO.md"
	if [[ ! -f "$todo_file" ]]; then
		log_verbose "Phase 7b: Skipped (no TODO.md at $repo_path)"
		return 0
	fi

	local batch_filter=""
	if [[ -n "$batch_id" ]]; then
		local escaped_batch
		escaped_batch=$(sql_escape "$batch_id")
		batch_filter="AND EXISTS (SELECT 1 FROM batch_tasks bt WHERE bt.task_id = t.id AND bt.batch_id = '$escaped_batch')"
	fi

	local fixed_count=0
	local issue_count=0

	# --- Gap 1: DB failed/blocked but TODO.md has no annotation ---
	local failed_tasks
	failed_tasks=$(db -separator '|' "$SUPERVISOR_DB" "
		SELECT t.id, t.status, t.error FROM tasks t
		WHERE t.status IN ('failed', 'blocked')
		$batch_filter
		ORDER BY t.id;
	")

	if [[ -n "$failed_tasks" ]]; then
		while IFS='|' read -r tid tstatus terror; do
			[[ -z "$tid" ]] && continue

			# Check if task is open in TODO.md with no Notes annotation
			local line_num
			line_num=$(grep -nE "^[[:space:]]*- \[ \] ${tid}( |$)" "$todo_file" | head -1 | cut -d: -f1)
			[[ -z "$line_num" ]] && continue

			# Check if a Notes line already exists below
			local next_line_num=$((line_num + 1))
			local next_line
			next_line=$(sed -n "${next_line_num}p" "$todo_file" 2>/dev/null || echo "")

			if echo "$next_line" | grep -qE "^[[:space:]]*- Notes:"; then
				# Notes already present — skip
				continue
			fi

			issue_count=$((issue_count + 1))

			if [[ "$dry_run" == "true" ]]; then
				log_warn "[dry-run] $tid: DB status=$tstatus but TODO.md has no annotation"
			else
				log_info "Phase 7b: Annotating $tid ($tstatus) in TODO.md"
				local reason="${terror:-no error details}"
				update_todo_on_blocked "$tid" "$reason" 2>>"${SUPERVISOR_LOG:-/dev/null}" || {
					log_warn "Phase 7b: Failed to annotate $tid"
					continue
				}
				fixed_count=$((fixed_count + 1))
			fi
		done <<<"$failed_tasks"
	fi

	# --- Gap 2: TODO.md [x] but DB still in non-terminal state ---
	# Terminal states: complete, deployed, verified, failed, blocked, cancelled
	# Non-terminal: queued, dispatched, running, evaluating, retrying,
	#   pr_review, review_triage, merging, merged, deploying, verifying, verify_failed
	local all_db_tasks
	all_db_tasks=$(db -separator '|' "$SUPERVISOR_DB" "
		SELECT t.id, t.status FROM tasks t
		WHERE t.status NOT IN ('complete', 'deployed', 'verified', 'failed', 'blocked', 'cancelled')
		$batch_filter
		ORDER BY t.id;
	")

	if [[ -n "$all_db_tasks" ]]; then
		while IFS='|' read -r tid tstatus; do
			[[ -z "$tid" ]] && continue

			# Check if this task is marked [x] in TODO.md
			if grep -qE "^[[:space:]]*- \[x\] ${tid}( |$)" "$todo_file"; then
				issue_count=$((issue_count + 1))

				if [[ "$dry_run" == "true" ]]; then
					log_warn "[dry-run] $tid: marked [x] in TODO.md but DB status=$tstatus"
				else
					log_info "Phase 7b: Transitioning $tid from $tstatus to complete (TODO.md shows [x])"
					cmd_transition "$tid" "complete" \
						--reason "Reconciled: TODO.md marked [x] but DB was $tstatus (t1001)" \
						2>>"${SUPERVISOR_LOG:-/dev/null}" || {
						log_warn "Phase 7b: Failed to transition $tid to complete"
						continue
					}
					fixed_count=$((fixed_count + 1))
				fi
			fi
		done <<<"$all_db_tasks"
	fi

	# --- Gap 3: DB orphans — tasks in DB with no TODO.md entry at all ---
	local orphan_tasks
	orphan_tasks=$(db -separator '|' "$SUPERVISOR_DB" "
		SELECT t.id, t.status FROM tasks t
		WHERE t.status NOT IN ('cancelled')
		$batch_filter
		ORDER BY t.id;
	")

	local orphan_count=0
	local orphan_ids=""

	if [[ -n "$orphan_tasks" ]]; then
		while IFS='|' read -r tid tstatus; do
			[[ -z "$tid" ]] && continue

			# Check if task ID appears anywhere in TODO.md (open, closed, or in notes)
			if ! grep -qE "(^|[[:space:]])${tid}([[:space:]]|$)" "$todo_file"; then
				orphan_count=$((orphan_count + 1))
				orphan_ids="${orphan_ids}${orphan_ids:+, }${tid}(${tstatus})"
			fi
		done <<<"$orphan_tasks"
	fi

	if [[ "$orphan_count" -gt 0 ]]; then
		issue_count=$((issue_count + orphan_count))
		log_warn "Phase 7b: $orphan_count DB orphan(s) with no TODO.md entry: $orphan_ids"
		# Orphans are logged but not auto-fixed — they may be from other repos
		# or manually managed tasks. The warning enables human review.
	fi

	# Summary
	if [[ "$issue_count" -eq 0 ]]; then
		log_verbose "Phase 7b: DB and TODO.md are in sync (no drift detected)"
	elif [[ "$dry_run" == "true" ]]; then
		log_warn "Phase 7b: $issue_count inconsistency(ies) found (dry-run, no changes made)"
	else
		log_success "Phase 7b: Fixed $fixed_count/$issue_count inconsistency(ies)"
	fi

	return 0
}
