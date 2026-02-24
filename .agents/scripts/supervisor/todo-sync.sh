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
# Phase 0.5e: Stale-claim auto-recovery (t1263)
#
# When interactive sessions claim tasks (assignee: + started:) but die or
# move on without completing them, the tasks become permanently stuck:
# auto-pickup skips them because they have assignee/started fields, but no
# worker is running. This function detects and recovers those stale claims.
#
# Detection criteria (ALL must be true):
#   1. Task is open ([ ]) in TODO.md with assignee: and/or started: fields
#   2. Task is NOT in the supervisor DB as running/dispatched/evaluating
#      (i.e., no active worker process is tracked for it)
#   3. No active git worktree exists for the task
#   4. Claim age exceeds threshold (default: 24h)
#
# Safety (t1017 assignee ownership rule):
#   - Only unclaims tasks where assignee matches the local user identity
#   - External contributors' claims are NEVER touched
#
# Args:
#   $1 - repo path containing TODO.md
#
# Returns:
#   0 on success (including no stale claims found)
#   1 on failure (TODO.md not found)
#######################################
recover_stale_claims() {
	local repo_path="$1"
	local todo_file="$repo_path/TODO.md"

	if [[ ! -f "$todo_file" ]]; then
		log_verbose "recover_stale_claims: TODO.md not found at $todo_file"
		return 1
	fi

	# Configurable stale threshold in seconds (default: 24 hours)
	local stale_threshold="${SUPERVISOR_STALE_CLAIM_SECONDS:-86400}"

	local identity
	identity=$(get_aidevops_identity)

	local now_epoch
	now_epoch=$(date +%s 2>/dev/null || echo "0")

	# Get list of active worktrees for cross-referencing
	local active_worktrees=""
	active_worktrees=$(git -C "$repo_path" worktree list --porcelain 2>/dev/null | grep '^worktree ' | sed 's/^worktree //' || true)

	# Get list of tasks currently in active states in the supervisor DB
	local active_db_tasks=""
	if [[ -n "${SUPERVISOR_DB:-}" && -f "${SUPERVISOR_DB}" ]]; then
		active_db_tasks=$(db "$SUPERVISOR_DB" "
			SELECT id FROM tasks
			WHERE status IN ('running', 'dispatched', 'evaluating', 'queued', 'pr_review', 'review_triage', 'merging')
			ORDER BY id;
		" 2>/dev/null || true)
	fi

	local recovered_count=0
	local skipped_external=0
	local skipped_active=0
	local skipped_young=0
	local recovered_ids=""

	# Pre-compute identity variants for ownership checks (loop-invariant)
	local local_user
	local_user=$(whoami 2>/dev/null || echo "")
	local gh_user="${_CACHED_GH_USERNAME:-}"
	local identity_user="${identity%%@*}"

	# Find all open tasks with assignee: or started: fields
	while IFS= read -r line; do
		[[ -z "$line" ]] && continue

		# Extract task ID
		local task_id=""
		task_id=$(printf '%s' "$line" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1 || echo "")
		[[ -z "$task_id" ]] && continue

		# Extract assignee value
		local assignee=""
		assignee=$(printf '%s' "$line" | grep -oE 'assignee:[A-Za-z0-9._@-]+' | tail -1 | sed 's/assignee://' || echo "")

		# Extract started timestamp
		local started_ts=""
		started_ts=$(printf '%s' "$line" | grep -oE 'started:[0-9T:Z-]+' | tail -1 | sed 's/started://' || echo "")

		# Safety check: only unclaim tasks assigned to the local user (t1017)
		# Tasks with started: but no assignee: are treated as external — we cannot
		# verify ownership without the assignee field, so skipping is the safe default.
		if [[ -n "$assignee" ]]; then
			local is_local_user=false

			# Check exact match
			if [[ "$assignee" == "$identity" ]]; then
				is_local_user=true
			fi

			# Fuzzy match: username portion (before @)
			if [[ "$is_local_user" == "false" ]]; then
				if [[ "$assignee" == "$local_user" ]] ||
					[[ -n "$gh_user" && "$assignee" == "$gh_user" ]] ||
					[[ "$assignee" == "$identity_user" ]] ||
					[[ "${assignee%%@*}" == "$identity_user" ]]; then
					is_local_user=true
				fi
			fi

			if [[ "$is_local_user" == "false" ]]; then
				skipped_external=$((skipped_external + 1))
				log_verbose "  Phase 0.5e: $task_id skipped — assignee:$assignee is not local user ($identity)"
				continue
			fi
		else
			# No assignee: field — cannot verify ownership; skip to protect external contributors
			# (Normal claim flow always writes both assignee: and started: together)
			skipped_external=$((skipped_external + 1))
			log_verbose "  Phase 0.5e: $task_id skipped — started: without assignee: (ownership unverifiable)"
			continue
		fi

		# Check 1: Is the task actively tracked in the supervisor DB?
		if [[ -n "$active_db_tasks" ]]; then
			if echo "$active_db_tasks" | grep -qE "^${task_id}$"; then
				skipped_active=$((skipped_active + 1))
				log_verbose "  Phase 0.5e: $task_id skipped — active in supervisor DB"
				continue
			fi
		fi

		# Check 2: Is there an active worktree for this task?
		local has_worktree=false
		if [[ -n "$active_worktrees" ]]; then
			# Match worktree paths containing the task ID (e.g., repo.feature-t1263)
			if echo "$active_worktrees" | grep -qE "[-./]${task_id}([^0-9.]|$)"; then
				has_worktree=true
			fi
		fi

		if [[ "$has_worktree" == "true" ]]; then
			skipped_active=$((skipped_active + 1))
			log_verbose "  Phase 0.5e: $task_id skipped — active worktree exists"
			continue
		fi

		# Check 3: Is the claim old enough? (>threshold seconds)
		if [[ -n "$started_ts" ]]; then
			local started_epoch=0
			started_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$started_ts" "+%s" 2>/dev/null ||
				date -d "$started_ts" "+%s" 2>/dev/null ||
				echo "0")

			if [[ "$started_epoch" -eq 0 ]]; then
				# Parse failure — unknown age; skip conservatively rather than treating as stale
				log_warn "  Phase 0.5e: $task_id skipped — could not parse started: timestamp '${started_ts}'"
				skipped_young=$((skipped_young + 1))
				continue
			fi

			local claim_age=$((now_epoch - started_epoch))
			if [[ "$claim_age" -lt "$stale_threshold" ]]; then
				skipped_young=$((skipped_young + 1))
				local remaining=$(((stale_threshold - claim_age) / 3600))
				log_verbose "  Phase 0.5e: $task_id skipped — claim age ${claim_age}s < threshold ${stale_threshold}s (~${remaining}h remaining)"
				continue
			fi
		else
			# No started: timestamp — use a heuristic: if assignee: exists but no
			# started:, the claim is malformed. Still check age via git blame if
			# possible, but default to treating it as stale (it's already orphaned
			# from the normal claim flow which always sets both fields).
			log_verbose "  Phase 0.5e: $task_id has assignee: but no started: — treating as stale (malformed claim)"
		fi

		# All checks passed — this is a stale claim. Unclaim it.
		log_warn "  Phase 0.5e: Stale claim detected — $task_id (assignee:${assignee:-unknown}, started:${started_ts:-unknown})"

		# Use cmd_unclaim with --force to strip assignee: and started: fields
		if cmd_unclaim "$task_id" "$repo_path" --force 2>>"${SUPERVISOR_LOG:-/dev/null}"; then
			recovered_count=$((recovered_count + 1))
			if [[ -n "$recovered_ids" ]]; then
				recovered_ids="${recovered_ids}, ${task_id}"
			else
				recovered_ids="$task_id"
			fi
			log_success "  Phase 0.5e: Recovered $task_id — assignee: and started: stripped, task is now dispatchable"
		else
			log_warn "  Phase 0.5e: Failed to unclaim $task_id"
		fi
	done < <(grep -E '^\s*- \[ \] t[0-9]+.*(assignee:|started:)' "$todo_file" || true)

	# Summary
	if [[ "$recovered_count" -gt 0 ]]; then
		log_success "Phase 0.5e: Recovered $recovered_count stale claim(s): $recovered_ids (skipped: $skipped_external external, $skipped_active active, $skipped_young young)"

		# Record pattern for observability
		local pattern_helper="${SCRIPT_DIR:-}/pattern-tracker-helper.sh"
		if [[ -x "$pattern_helper" ]]; then
			"$pattern_helper" record \
				--type "SELF_HEAL_PATTERN" \
				--task "supervisor" \
				--model "n/a" \
				--detail "Phase 0.5e stale-claim recovery (t1263): $recovered_count claims recovered ($recovered_ids), threshold=${stale_threshold}s" \
				2>/dev/null || true
		fi
	else
		log_verbose "Phase 0.5e: No stale claims detected (skipped: $skipped_external external, $skipped_active active, $skipped_young young)"
	fi

	return 0
}

#######################################
# Commit and push todo/VERIFY.md with pull-rebase retry (t1053)
# Handles concurrent push conflicts from parallel workers
# Args: $1=repo_path $2=commit_message $3=max_retries (default 3)
#######################################
commit_and_push_verify() {
	local repo_path="$1"
	local commit_msg="$2"
	local max_retries="${3:-3}"

	local verify_rel="todo/VERIFY.md"

	if git -C "$repo_path" diff --quiet -- "$verify_rel" 2>>"$SUPERVISOR_LOG"; then
		log_info "No changes to commit (VERIFY.md unchanged)"
		return 0
	fi

	git -C "$repo_path" add "$verify_rel"

	local attempt=0
	while [[ "$attempt" -lt "$max_retries" ]]; do
		attempt=$((attempt + 1))

		# Pull-rebase to incorporate any concurrent pushes
		if ! git -C "$repo_path" pull --rebase --autostash 2>>"$SUPERVISOR_LOG"; then
			log_warn "Pull-rebase failed for VERIFY.md (attempt $attempt/$max_retries)"
			git -C "$repo_path" rebase --abort 2>>"$SUPERVISOR_LOG" || true
			sleep "$attempt"
			continue
		fi

		# Re-stage VERIFY.md (rebase may have resolved it)
		if ! git -C "$repo_path" diff --quiet -- "$verify_rel" 2>>"$SUPERVISOR_LOG"; then
			git -C "$repo_path" add "$verify_rel"
		fi

		# Check if our change survived the rebase
		if git -C "$repo_path" diff --cached --quiet -- "$verify_rel" 2>>"$SUPERVISOR_LOG"; then
			log_info "VERIFY.md change already applied (likely by another worker)"
			return 0
		fi

		# Commit
		if ! git -C "$repo_path" commit -m "$commit_msg" -- "$verify_rel" 2>>"$SUPERVISOR_LOG"; then
			log_warn "Commit failed for VERIFY.md (attempt $attempt/$max_retries)"
			sleep "$attempt"
			continue
		fi

		# Push
		if git -C "$repo_path" push 2>>"$SUPERVISOR_LOG"; then
			log_success "Committed and pushed VERIFY.md update"
			return 0
		fi

		log_warn "Push failed for VERIFY.md (attempt $attempt/$max_retries) - will pull-rebase and retry"
		sleep "$attempt"
	done

	log_error "Failed to push VERIFY.md after $max_retries attempts"
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

	# Recover tasks stuck in 'verifying' state (t1075)
	# If a pulse crashes mid-verification, tasks stay in 'verifying' forever.
	# Reset any task that has been in 'verifying' for more than 5 minutes back to 'deployed'.
	local stuck_verifying
	stuck_verifying=$(db -separator '|' "$SUPERVISOR_DB" "
		SELECT id FROM tasks
		WHERE status = 'verifying'
		  AND updated_at < strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-5 minutes')
		ORDER BY id;
	" 2>/dev/null || echo "")

	if [[ -n "$stuck_verifying" ]]; then
		while IFS='|' read -r stuck_id; do
			[[ -z "$stuck_id" ]] && continue
			log_warn "  $stuck_id: stuck in 'verifying' for >5min — resetting to 'deployed'"
			local escaped_stuck_id
			escaped_stuck_id=$(sql_escape "$stuck_id")
			db "$SUPERVISOR_DB" "UPDATE tasks SET
				status = 'deployed',
				error = NULL,
				updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
			WHERE id = '$escaped_stuck_id';" 2>/dev/null || true
			db "$SUPERVISOR_DB" "INSERT INTO state_log (task_id, from_state, to_state, timestamp, reason)
			VALUES ('$escaped_stuck_id', 'verifying', 'deployed',
				strftime('%Y-%m-%dT%H:%M:%SZ','now'),
				'process_verify_queue: recovered from stuck verifying state (>5min timeout)');" 2>/dev/null || true
		done <<<"$stuck_verifying"
	fi

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
	local auto_verified_count=0
	local max_auto_verify_per_pulse=50

	while IFS='|' read -r tid trepo _tpr; do
		[[ -z "$tid" ]] && continue

		local verify_file="$trepo/todo/VERIFY.md"
		local has_entry=false

		if [[ -f "$verify_file" ]] && grep -q "^- \[ \] v[0-9]* $tid " "$verify_file" 2>/dev/null; then
			has_entry=true
		fi

		if [[ "$has_entry" == "true" ]]; then
			# Has VERIFY.md entry — run the defined checks
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
		else
			# No VERIFY.md entry — auto-verify (PR merged + CI passed is sufficient)
			# Rate-limit to avoid overwhelming the state machine in one pulse
			if [[ "$auto_verified_count" -ge "$max_auto_verify_per_pulse" ]]; then
				continue
			fi
			cmd_transition "$tid" "verified" 2>>"$SUPERVISOR_LOG" || {
				log_warn "  $tid: failed to auto-verify"
				continue
			}
			auto_verified_count=$((auto_verified_count + 1))
		fi
	done <<<"$deployed_tasks"

	if [[ $((verified_count + failed_count + auto_verified_count)) -gt 0 ]]; then
		log_info "Verification: $verified_count passed, $failed_count failed, $auto_verified_count auto-verified (no VERIFY.md entry)"
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

	# Verify deliverables before marking complete (t163.4, t1314.1: AI judgment)
	local _verify_func="verify_task_deliverables"
	if declare -f ai_verify_task_deliverables &>/dev/null; then
		_verify_func="ai_verify_task_deliverables"
	fi
	if ! "$_verify_func" "$task_id" "$tpr_url" "$trepo"; then
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

	# Mark as complete: [ ] -> [x], append proof-log and completed:date
	# Proof-log: pr:#NNN if PR found, otherwise verified:date (t1004)
	local proof_log=""
	if [[ -n "$pr_number" ]]; then
		proof_log=" pr:#${pr_number}"
	else
		proof_log=" verified:${today}"
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
#   - .toon/.yml/.yaml/.json: file-exists
#   - test files: bash <test>
#   - .agents/ .md files: rg for subagent-index entries
#   - other: file-exists
# Filters out planning files (TODO.md, todo/)
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

	# Truncate description to 60 chars for the entry header
	local short_desc="$tdesc"
	if [[ ${#short_desc} -gt 60 ]]; then
		short_desc="${short_desc:0:57}..."
	fi

	# Get files changed in PR (single gh call, requires gh CLI)
	local -a changed_files=()
	local -a substantive_files=()
	local -a check_lines=()

	if [[ -n "$pr_number" ]] && command -v gh &>/dev/null && check_gh_auth; then
		local repo_slug=""
		repo_slug=$(detect_repo_slug "$trepo" 2>/dev/null || echo "")
		if [[ -n "$repo_slug" ]]; then
			# Single gh call — store result for both file list and check generation
			local pr_files_raw=""
			pr_files_raw=$(gh pr view "$pr_number" --repo "$repo_slug" --json files --jq '.files[].path' 2>/dev/null || echo "")

			while IFS= read -r fpath; do
				[[ -z "$fpath" ]] && continue
				changed_files+=("$fpath")
			done <<<"$pr_files_raw"

			# Filter out planning files (TODO.md, todo/*)
			local fpath
			for fpath in "${changed_files[@]}"; do
				case "$fpath" in
				TODO.md | todo/* | .task-counter)
					continue
					;;
				*)
					substantive_files+=("$fpath")
					;;
				esac
			done

			# Generate check directives based on file types
			for fpath in "${substantive_files[@]}"; do
				case "$fpath" in
				*.sh)
					check_lines+=("  check: shellcheck $fpath")
					check_lines+=("  check: file-exists $fpath")
					;;
				*.toon)
					check_lines+=("  check: file-exists $fpath")
					;;
				*.yml | *.yaml)
					check_lines+=("  check: file-exists $fpath")
					;;
				*.json)
					check_lines+=("  check: file-exists $fpath")
					;;
				*.md)
					check_lines+=("  check: file-exists $fpath")
					;;
				*)
					check_lines+=("  check: file-exists $fpath")
					;;
				esac
			done

			# Add subagent-index checks for .agents/ tool/service/workflow .md files
			for fpath in "${substantive_files[@]}"; do
				if [[ "$fpath" =~ ^\.agents/(tools|services|workflows)/.+\.md$ ]]; then
					local bname
					bname=$(basename "$fpath" .md)
					check_lines+=("  check: rg \"$bname\" .agents/subagent-index.toon")
				fi
			done
		fi
	fi

	# Skip if no substantive files changed
	if [[ ${#substantive_files[@]} -eq 0 && ${#changed_files[@]} -gt 0 ]]; then
		log_info "generate_verify_entry: no substantive files in PR #${pr_number:-unknown} for $task_id"
		return 0
	fi

	# Fallback: if no checks generated and no files found, add basic check
	if [[ ${#check_lines[@]} -eq 0 && -n "$pr_number" ]]; then
		check_lines+=("  check: rg \"$task_id\" TODO.md")
	fi

	# Build files list (comma-separated with spaces)
	local files_list=""
	if [[ ${#substantive_files[@]} -gt 0 ]]; then
		files_list=$(printf '%s\n' "${substantive_files[@]}" | paste -sd ',' - | sed 's/,/, /g')
	fi

	# Build the entry
	local entry_header="- [ ] $vid $task_id $short_desc | PR #${pr_number:-unknown} | merged:$today"
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
		# No marker — append to end of file instead
		log_info "generate_verify_entry: no VERIFY-QUEUE-END marker, appending to end"
		{
			echo ""
			printf '%s\n' "$entry_header"
			printf '%s' "$entry_body"
		} >>"$verify_file"
	else
		# Build full entry text
		local full_entry
		full_entry=$(printf '%s\n%s' "$entry_header" "$entry_body")

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
	fi

	log_success "Generated verify entry $vid for $task_id (PR #${pr_number:-unknown})"

	# Commit and push VERIFY.md (not TODO.md)
	commit_and_push_verify "$trepo" "chore: add verify entry $vid for $task_id" 2>>"$SUPERVISOR_LOG" || true

	return 0
}

#######################################
# Update TODO.md when a task is cancelled by the supervisor
# Adds Notes line with cancellation reason (does NOT mark [x] — cancelled != done)
# Then commits and pushes the change (t1139)
#######################################
update_todo_on_cancelled() {
	local task_id="$1"
	local reason="${2:-cancelled by supervisor}"

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

	# Find the task line number (open checkbox only — already-closed tasks are fine)
	local line_num
	line_num=$(grep -nE "^[[:space:]]*- \[ \] ${task_id}( |$)" "$todo_file" | head -1 | cut -d: -f1)

	if [[ -z "$line_num" ]]; then
		log_verbose "Task $task_id not found as open in $todo_file (already annotated or closed)"
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
		# Check if CANCELLED annotation already present — avoid duplicates
		if echo "$next_line" | grep -q "CANCELLED:"; then
			log_verbose "Task $task_id already has CANCELLED annotation — skipping"
			return 0
		fi
		# Append to existing Notes line
		local append_text=" CANCELLED: ${safe_reason}"
		sed_inplace "${next_line_num}s/$/${append_text}/" "$todo_file"
	else
		# Insert a new Notes line after the task
		local notes_line="${indent}  - Notes: CANCELLED: ${safe_reason}"
		sed_append_after "$line_num" "$notes_line" "$todo_file"
	fi

	log_success "Updated TODO.md: $task_id annotated as cancelled ($reason)"

	commit_and_push_todo "$trepo" "chore: annotate $task_id cancelled in TODO.md (t1139)"
	return $?
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
# t1243: Auto-unblock tasks whose blocked-by dependencies are all resolved.
# Scans TODO.md for open tasks with blocked-by: fields, checks whether
# all blockers are completed ([x]) or declined ([-]), and removes the
# blocked-by: field from tasks that are fully unblocked.
#
# This enables the supervisor to automatically detect when blocking tasks
# transition to verified/completed and make dependent tasks dispatchable
# without manual intervention.
#
# Args:
#   $1 - repo path
#
# Returns:
#   0 on success (even if no tasks were unblocked)
#   1 on failure (TODO.md not found)
#######################################
auto_unblock_resolved_tasks() {
	local repo_path="$1"
	local todo_file="$repo_path/TODO.md"

	if [[ ! -f "$todo_file" ]]; then
		log_verbose "auto_unblock_resolved_tasks: TODO.md not found at $todo_file"
		return 1
	fi

	local unblocked_count=0
	local unblocked_ids=""

	# Find all open tasks with blocked-by: field
	while IFS= read -r line; do
		local task_id=""
		task_id=$(printf '%s' "$line" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1 || echo "")
		[[ -z "$task_id" ]] && continue

		# Extract blocked-by dependencies
		local blocked_by=""
		blocked_by=$(printf '%s' "$line" | grep -oE 'blocked-by:[^ ]+' | head -1 | sed 's/blocked-by://' || echo "")
		[[ -z "$blocked_by" ]] && continue

		# Check each blocker
		local all_resolved=true
		local _saved_ifs="$IFS"
		IFS=','
		for blocker_id in $blocked_by; do
			[[ -z "$blocker_id" ]] && continue

			# Check if blocker is completed ([x]) or declined ([-])
			if grep -qE "^[[:space:]]*- \[x\] ${blocker_id}( |$)" "$todo_file" 2>/dev/null; then
				continue # Resolved
			fi
			if grep -qE "^[[:space:]]*- \[-\] ${blocker_id}( |$)" "$todo_file" 2>/dev/null; then
				continue # Declined = resolved
			fi

			# t1247: DB fallback — blocker may be deployed/verified in DB but TODO.md
			# not yet updated (update_todo_on_complete runs AFTER Phase 0.5d in the same
			# pulse, or may have failed due to deliverable verification / subtask guard).
			# Treat deployed/verified/complete/merged DB status as resolved so downstream
			# tasks are unblocked atomically without waiting for the next pulse.
			if [[ -n "${SUPERVISOR_DB:-}" && -f "${SUPERVISOR_DB}" ]]; then
				local blocker_db_status=""
				blocker_db_status=$(db "$SUPERVISOR_DB" \
					"SELECT status FROM tasks WHERE id = '$(sql_escape "$blocker_id")' LIMIT 1;" \
					2>/dev/null || echo "")
				if [[ "$blocker_db_status" == "complete" ||
					"$blocker_db_status" == "deployed" ||
					"$blocker_db_status" == "verified" ||
					"$blocker_db_status" == "merged" ]]; then
					log_verbose "  auto-unblock: blocker $blocker_id is '$blocker_db_status' in DB (TODO.md not yet updated) — treating as resolved"
					continue # Resolved in DB
				fi
			fi

			# Check if blocker is permanently failed in DB (retries exhausted)
			# A failed blocker will never complete — don't let it block dependents forever
			if [[ -n "${SUPERVISOR_DB:-}" && -f "${SUPERVISOR_DB}" ]]; then
				local blocker_failed_status=""
				blocker_failed_status=$(db "$SUPERVISOR_DB" \
					"SELECT status FROM tasks WHERE id = '$(sql_escape "$blocker_id")' AND status = 'failed' LIMIT 1;" \
					2>/dev/null || echo "")
				if [[ "$blocker_failed_status" == "failed" ]]; then
					local blocker_retries_left blocker_max_retries_left
					blocker_retries_left=$(db "$SUPERVISOR_DB" "SELECT COALESCE(retries, 0) FROM tasks WHERE id = '$(sql_escape "$blocker_id")';" 2>/dev/null || echo "")
					blocker_max_retries_left=$(db "$SUPERVISOR_DB" "SELECT COALESCE(max_retries, 3) FROM tasks WHERE id = '$(sql_escape "$blocker_id")';" 2>/dev/null || echo "")
					# Guard against empty strings from race conditions or db failure
					# Default max_retries to 3 (not 0) so db failure doesn't falsely
					# trigger "retries exhausted" and prematurely unblock dependents
					blocker_retries_left="${blocker_retries_left:-0}"
					blocker_max_retries_left="${blocker_max_retries_left:-3}"
					if [[ "$blocker_retries_left" -ge "$blocker_max_retries_left" ]]; then
						log_verbose "  auto-unblock: blocker $blocker_id is permanently failed in DB ($blocker_retries_left/$blocker_max_retries_left retries) — treating as resolved"
						continue # Permanently failed = treat as resolved
					fi
				fi
			fi

			# Check if blocker doesn't exist in TODO.md at all (orphaned reference)
			if ! grep -qE "^[[:space:]]*- \[.\] ${blocker_id}( |$)" "$todo_file" 2>/dev/null; then
				continue # Non-existent blocker = resolved
			fi

			# Blocker is still open — task remains blocked
			all_resolved=false
			break
		done
		IFS="$_saved_ifs"

		if [[ "$all_resolved" == "true" ]]; then
			# Remove blocked-by: field from the task line
			# Find the line number first, then do a targeted replacement
			local line_num
			line_num=$(grep -nE "^[[:space:]]*- \[ \] ${task_id}( |$)" "$todo_file" | head -1 | cut -d: -f1 || echo "")
			if [[ -n "$line_num" ]]; then
				# Remove ' blocked-by:<value>' from the specific line
				# Escape dots in task IDs for sed regex (e.g., t1224.3 → t1224\.3)
				local escaped_blocked_by
				escaped_blocked_by=$(printf '%s' "$blocked_by" | sed 's/\./\\./g')
				sed_inplace "${line_num}s/ blocked-by:${escaped_blocked_by}//" "$todo_file"
				# Clean up any trailing whitespace left behind
				sed_inplace "${line_num}s/[[:space:]]*$//" "$todo_file"
			fi

			unblocked_count=$((unblocked_count + 1))
			if [[ -n "$unblocked_ids" ]]; then
				unblocked_ids="${unblocked_ids}, ${task_id}"
			else
				unblocked_ids="$task_id"
			fi
			log_info "  auto-unblock: $task_id — all blockers resolved (was: blocked-by:$blocked_by)"
		fi
	done < <(grep -E '^\s*- \[ \] t[0-9]+.*blocked-by:' "$todo_file" || true)

	if [[ "$unblocked_count" -gt 0 ]]; then
		log_success "auto_unblock_resolved_tasks: unblocked $unblocked_count task(s): $unblocked_ids"
		commit_and_push_todo "$repo_path" "chore: auto-unblock $unblocked_count task(s) with resolved blockers: $unblocked_ids"
	else
		log_verbose "auto_unblock_resolved_tasks: no tasks to unblock"
	fi

	return 0
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
	failed | cancelled)
		local terror
		terror=$(db "$SUPERVISOR_DB" "SELECT error FROM tasks WHERE id = '$escaped_id';")
		if [[ "$tstatus" == "failed" ]]; then
			update_todo_on_blocked "$task_id" "FAILED: ${terror:-unknown}"
		else
			update_todo_on_cancelled "$task_id" "${terror:-cancelled by supervisor}"
		fi
		;;
	*)
		log_warn "Task $task_id is in '$tstatus' state - TODO update only applies to complete/deployed/merged/blocked/failed/cancelled tasks"
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
# Phase 0.5b: Deduplicate task IDs in TODO.md (t319.4, t1069)
# Scans TODO.md for duplicate task IDs on multiple open `- [ ]` lines.
# Keeps the first occurrence, removes subsequent duplicates.
# Never renames — renaming created ghost task IDs that polluted tracking.
# Commits and pushes changes if any duplicates were removed.
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

	log_warn "Phase 0.5b: Duplicate task IDs found in TODO.md, removing duplicates..."

	# Collect line numbers to delete (all duplicate occurrences except the first)
	local lines_to_delete=""
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

			log_warn "    Removing: line $line_num ($dup_id) — duplicate of kept line"
			lines_to_delete="${lines_to_delete} ${line_num}"
			changes_made=$((changes_made + 1))
		done <<<"$occurrences"
	done <<<"$dup_ids"

	# Delete lines in reverse order so line numbers remain valid
	if [[ "$changes_made" -gt 0 && -n "$lines_to_delete" ]]; then
		# Sort line numbers in descending order for safe deletion
		local sorted_lines
		sorted_lines=$(echo "$lines_to_delete" | tr ' ' '\n' | sort -rn | grep -v '^$')

		while IFS= read -r line_num; do
			[[ -z "$line_num" ]] && continue
			sed_inplace "${line_num}d" "$todo_file"
		done <<<"$sorted_lines"

		log_success "Phase 0.5b: Removed $changes_made duplicate task line(s) from TODO.md"
		commit_and_push_todo "$repo_path" "chore: remove $changes_made duplicate task line(s) from TODO.md (t1069)"
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

	# --- Gap 1: DB failed/blocked/cancelled but TODO.md has no annotation ---
	# t1139: Extended to include 'cancelled' — previously only failed/blocked were covered.
	local failed_tasks
	failed_tasks=$(db -separator '|' "$SUPERVISOR_DB" "
		SELECT t.id, t.status, t.error FROM tasks t
		WHERE t.status IN ('failed', 'blocked', 'cancelled')
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
				if [[ "$tstatus" == "cancelled" ]]; then
					update_todo_on_cancelled "$tid" "$reason" 2>>"${SUPERVISOR_LOG:-/dev/null}" || {
						log_warn "Phase 7b: Failed to annotate $tid"
						continue
					}
				else
					update_todo_on_blocked "$tid" "$reason" 2>>"${SUPERVISOR_LOG:-/dev/null}" || {
						log_warn "Phase 7b: Failed to annotate $tid"
						continue
					}
				fi
				fixed_count=$((fixed_count + 1))
			fi
		done <<<"$failed_tasks"
	fi

	# --- Gap 1b: t1131 — DB cancelled but TODO.md still shows [ ] ---
	local cancelled_tasks
	cancelled_tasks=$(db "$SUPERVISOR_DB" "
		SELECT t.id FROM tasks t
		WHERE t.status = 'cancelled'
		$batch_filter
		ORDER BY t.id;
	")

	if [[ -n "$cancelled_tasks" ]]; then
		while IFS= read -r tid; do
			[[ -z "$tid" ]] && continue

			# Only act if task is still open ([ ]) in TODO.md
			if ! grep -qE "^[[:space:]]*- \[ \] ${tid}( |$)" "$todo_file"; then
				continue
			fi

			issue_count=$((issue_count + 1))

			if [[ "$dry_run" == "true" ]]; then
				log_warn "[dry-run] $tid: DB status=cancelled but TODO.md still shows [ ]"
			else
				log_info "Phase 7b: Marking $tid cancelled in TODO.md (t1131)"
				update_todo_on_cancelled "$tid" "Retroactive sync from DB" 2>>"${SUPERVISOR_LOG:-/dev/null}" || {
					log_warn "Phase 7b: Failed to mark $tid cancelled in TODO.md"
					continue
				}
				fixed_count=$((fixed_count + 1))
			fi
		done <<<"$cancelled_tasks"
	fi

	# --- Gap 2: TODO.md [x] but DB still in non-terminal state ---
	# Terminal states: complete, deployed, verified, failed, blocked, cancelled, verify_failed
	# Non-terminal: queued, dispatched, running, evaluating, retrying,
	#   pr_review, review_triage, merging, merged, deploying, verifying
	# t1041: verify_failed is excluded — it's a meaningful state (PR merged+deployed
	# but post-merge checks failed). Re-verification handles these, not reconciliation.
	local all_db_tasks
	all_db_tasks=$(db -separator '|' "$SUPERVISOR_DB" "
		SELECT t.id, t.status FROM tasks t
		WHERE t.status NOT IN ('complete', 'deployed', 'verified', 'verify_failed', 'failed', 'blocked', 'cancelled')
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
						--error "Reconciled: TODO.md marked [x] but DB was $tstatus (t1001)" \
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

#######################################
# Command: reconcile-queue-dispatchability (t1180)
# Syncs DB queue state with TODO.md reality to eliminate phantom queue entries.
#
# Problem: tasks get queued in the DB via cmd_auto_pickup but their TODO.md
# state later diverges — they get completed, cancelled, or lose their
# #auto-dispatch tag. These phantom entries inflate queue metrics and confuse
# priority decisions because cmd_next() only queries DB status, not TODO.md.
#
# This function finds all DB tasks with status='queued' and checks each
# against TODO.md reality:
#   1. Task marked [x] in TODO.md → transition DB to 'complete'
#   2. Task marked [-] in TODO.md → transition DB to 'cancelled'
#   3. Task open [ ] but no #auto-dispatch tag AND not in Dispatch Queue
#      section → cancel in DB (was queued without valid dispatch criteria)
#   4. Task has assignee:/started: → skip (actively claimed, not phantom)
#   5. Task missing from TODO.md → skip (handled by Phase 7b Gap 3 orphan check)
#
# Arguments:
#   --repo <path>   - repo path (default: from DB or pwd)
#   --batch <id>    - filter to batch
#   --dry-run       - report only, don't modify
# Returns: 0 on success
#######################################
cmd_reconcile_queue_dispatchability() {
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
		log_verbose "Phase 0.6: Skipped (no TODO.md at $repo_path)"
		return 0
	fi

	local batch_filter=""
	if [[ -n "$batch_id" ]]; then
		local escaped_batch
		escaped_batch=$(sql_escape "$batch_id")
		batch_filter="AND EXISTS (SELECT 1 FROM batch_tasks bt WHERE bt.task_id = t.id AND bt.batch_id = '$escaped_batch')"
	fi

	# Get all queued tasks from DB
	local queued_tasks
	queued_tasks=$(db -separator '|' "$SUPERVISOR_DB" "
		SELECT t.id, t.repo FROM tasks t
		WHERE t.status = 'queued'
		$batch_filter
		ORDER BY t.id;
	" 2>/dev/null || echo "")

	if [[ -z "$queued_tasks" ]]; then
		log_verbose "Phase 0.6: No queued tasks in DB — skipping reconciliation"
		return 0
	fi

	# Build a set of task IDs in the Dispatch Queue section of TODO.md
	# (tasks in this section are dispatchable even without #auto-dispatch tag)
	local dispatch_queue_ids=""
	local in_dispatch_section=false
	while IFS= read -r dq_line; do
		if echo "$dq_line" | grep -qE '^#{1,3} '; then
			if echo "$dq_line" | grep -qi 'dispatch.queue'; then
				in_dispatch_section=true
			else
				in_dispatch_section=false
			fi
			continue
		fi
		if [[ "$in_dispatch_section" == "true" ]]; then
			local dq_id
			dq_id=$(echo "$dq_line" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1)
			if [[ -n "$dq_id" ]]; then
				dispatch_queue_ids="${dispatch_queue_ids} ${dq_id} "
			fi
		fi
	done <"$todo_file"

	local cancelled_count=0
	local completed_count=0
	local phantom_count=0
	local skipped_count=0

	while IFS='|' read -r tid trepo; do
		[[ -z "$tid" ]] && continue

		# Use the task's own repo if available, fall back to the provided repo_path
		local task_todo="$todo_file"
		if [[ -n "$trepo" && "$trepo" != "$repo_path" && -f "$trepo/TODO.md" ]]; then
			task_todo="$trepo/TODO.md"
		fi

		# --- Check 1: Task marked [x] (completed) in TODO.md ---
		if grep -qE "^[[:space:]]*- \[x\] ${tid}( |$)" "$task_todo" 2>/dev/null; then
			if [[ "$dry_run" == "true" ]]; then
				log_warn "[dry-run] Phase 0.6: $tid queued in DB but [x] in TODO.md — would transition to complete"
			else
				log_info "Phase 0.6: $tid queued in DB but [x] in TODO.md — transitioning to complete"
				cmd_transition "$tid" "complete" \
					--error "Reconciled: TODO.md marked [x] but DB was queued (t1180)" \
					2>>"${SUPERVISOR_LOG:-/dev/null}" || {
					log_warn "Phase 0.6: Failed to transition $tid to complete"
					continue
				}
				completed_count=$((completed_count + 1))
			fi
			continue
		fi

		# --- Check 2: Task marked [-] (cancelled) in TODO.md ---
		if grep -qE "^[[:space:]]*- \[-\] ${tid}( |$)" "$task_todo" 2>/dev/null; then
			if [[ "$dry_run" == "true" ]]; then
				log_warn "[dry-run] Phase 0.6: $tid queued in DB but [-] in TODO.md — would cancel"
			else
				log_info "Phase 0.6: $tid queued in DB but [-] in TODO.md — cancelling"
				cmd_transition "$tid" "cancelled" \
					--error "Reconciled: TODO.md marked [-] but DB was queued (t1180)" \
					2>>"${SUPERVISOR_LOG:-/dev/null}" || {
					log_warn "Phase 0.6: Failed to cancel $tid"
					continue
				}
				cancelled_count=$((cancelled_count + 1))
			fi
			continue
		fi

		# --- Check 3: Task open [ ] in TODO.md — verify it's still dispatchable ---
		local todo_line
		todo_line=$(grep -E "^[[:space:]]*- \[ \] ${tid}( |$)" "$task_todo" 2>/dev/null | head -1 || true)

		if [[ -z "$todo_line" ]]; then
			# t1261: Task queued in DB but not found in TODO.md at all — orphan.
			# This happens when _exec_create_task appends to TODO.md but
			# commit_and_push_todo fails (merge conflict), and the auto-pickup
			# phase adds the task to the DB from the local (uncommitted) copy.
			# The next git pull removes the local-only line, leaving a DB-only
			# task that can never be dispatched (dispatch requires TODO.md claim).
			# Cancel these orphans to prevent permanent dispatch stall.
			if [[ "$dry_run" == "true" ]]; then
				log_warn "[dry-run] Phase 0.6: $tid queued in DB but not in TODO.md — would cancel (orphaned, t1261)"
			else
				log_warn "Phase 0.6: $tid queued in DB but not in TODO.md — cancelling orphan (t1261)"
				db "$SUPERVISOR_DB" "UPDATE tasks SET status='cancelled', error='Orphaned: queued in DB but not found in TODO.md (t1261)' WHERE id='$(sql_escape "$tid")' AND status='queued';" 2>/dev/null || true
				phantom_count=$((phantom_count + 1))
			fi
			continue
		fi

		# Skip tasks with assignee: or started: — they are actively claimed
		if echo "$todo_line" | grep -qE '(assignee:|started:)'; then
			log_verbose "Phase 0.6: $tid has assignee/started — skipping (actively claimed)"
			skipped_count=$((skipped_count + 1))
			continue
		fi

		# Check if task has #auto-dispatch tag
		local has_auto_dispatch=false
		if echo "$todo_line" | grep -qE '#auto-dispatch'; then
			has_auto_dispatch=true
		fi

		# Check if task is in the Dispatch Queue section
		local in_dispatch_queue=false
		if echo "$dispatch_queue_ids" | grep -qE " ${tid} "; then
			in_dispatch_queue=true
		fi

		# If neither condition is met, this is a phantom queue entry
		if [[ "$has_auto_dispatch" == "false" && "$in_dispatch_queue" == "false" ]]; then
			phantom_count=$((phantom_count + 1))
			if [[ "$dry_run" == "true" ]]; then
				log_warn "[dry-run] Phase 0.6: $tid queued in DB but not dispatchable in TODO.md (no #auto-dispatch, not in Dispatch Queue)"
			else
				log_warn "Phase 0.6: $tid queued in DB but not dispatchable in TODO.md — cancelling phantom entry"
				cmd_transition "$tid" "cancelled" \
					--error "Reconciled: queued in DB but TODO.md has no #auto-dispatch tag or Dispatch Queue entry (t1180)" \
					2>>"${SUPERVISOR_LOG:-/dev/null}" || {
					log_warn "Phase 0.6: Failed to cancel phantom $tid"
					continue
				}
				cancelled_count=$((cancelled_count + 1))
			fi
		else
			log_verbose "Phase 0.6: $tid is dispatchable (has_auto_dispatch=$has_auto_dispatch, in_dispatch_queue=$in_dispatch_queue)"
		fi
	done <<<"$queued_tasks"

	# Summary
	local total_fixed=$((cancelled_count + completed_count))
	if [[ "$total_fixed" -eq 0 && "$phantom_count" -eq 0 ]]; then
		log_verbose "Phase 0.6: DB queue and TODO.md dispatchability are in sync"
	elif [[ "$dry_run" == "true" ]]; then
		log_warn "Phase 0.6: Found $phantom_count phantom(s), $completed_count completed, $cancelled_count cancelled (dry-run, no changes)"
	else
		if [[ "$total_fixed" -gt 0 ]]; then
			log_success "Phase 0.6: Reconciled $total_fixed phantom queue entry(ies) (completed: $completed_count, cancelled: $cancelled_count)"
		fi
	fi

	return 0
}
