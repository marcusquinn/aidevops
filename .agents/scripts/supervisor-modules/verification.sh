#!/usr/bin/env bash
# verification.sh - Post-merge verification module for supervisor
#
# Handles VERIFY.md queue processing, deliverable verification, and check execution.
# Part of the supervisor modularization (t311.3).
#
# Functions:
#   - verify_task_deliverables()  - Verify PR has substantive changes
#   - populate_verify_queue()     - Add task to VERIFY.md queue
#   - run_verify_checks()         - Execute check: directives
#   - mark_verify_entry()         - Mark entry as [x] or [!]
#   - process_verify_queue()      - Process all pending verifications
#   - cmd_verify()                - Manual verification command
#   - commit_verify_changes()     - Commit VERIFY.md updates
#
# Dependencies:
#   - db(), sql_escape() from main supervisor
#   - log_*() functions from main supervisor
#   - write_proof_log() from main supervisor
#   - parse_pr_url() from main supervisor
#   - validate_pr_belongs_to_task() from main supervisor
#   - check_gh_auth() from main supervisor
#   - cmd_transition() from lifecycle module
#   - send_task_notification() from todo-sync module
#   - SUPERVISOR_DB, SUPERVISOR_LOG globals

set -euo pipefail

#######################################
# Verify task deliverables (t163)
# Checks that a PR is merged and contains substantive file changes.
# Cross-contamination guard (t223): verifies PR references the task ID.
# Planning tasks (#plan, #audit, #chore, #docs) can have planning-only PRs (t261).
#
# Arguments:
#   $1 - task_id
#   $2 - pr_url (optional)
#   $3 - repo path (optional)
# Returns:
#   0 if deliverables verified, 1 otherwise
#######################################
verify_task_deliverables() {
	local task_id="$1"
	local pr_url="${2:-}"
	local repo="${3:-}"

	# Skip verification for diagnostic subtasks (they fix process, not deliverables)
	if [[ "$task_id" == *-diag-* ]]; then
		log_info "Skipping deliverable verification for diagnostic task $task_id"
		return 0
	fi

	# If no PR URL, task cannot be verified
	if [[ -z "$pr_url" || "$pr_url" == "no_pr" || "$pr_url" == "task_only" ]]; then
		log_warn "Task $task_id has no PR URL ($pr_url) - cannot verify deliverables"
		return 1
	fi

	# Extract repo slug and PR number from URL (t232)
	local parsed_verify repo_slug pr_number
	parsed_verify=$(parse_pr_url "$pr_url") || parsed_verify=""
	if [[ -z "$parsed_verify" ]]; then
		log_warn "Cannot parse PR URL for $task_id: $pr_url"
		return 1
	fi
	repo_slug="${parsed_verify%%|*}"
	pr_number="${parsed_verify##*|}"

	# Pre-flight: verify gh CLI is available and authenticated
	if ! command -v gh &>/dev/null; then
		log_warn "gh CLI not found; cannot verify deliverables for $task_id"
		return 1
	fi
	if ! check_gh_auth; then
		log_warn "gh CLI not authenticated; cannot verify deliverables for $task_id"
		return 1
	fi

	# Cross-contamination guard (t223): verify PR references this task ID
	# in its title or branch name before accepting it as a deliverable.
	local deliverable_validated
	deliverable_validated=$(validate_pr_belongs_to_task "$task_id" "$repo_slug" "$pr_url") || deliverable_validated=""
	if [[ -z "$deliverable_validated" ]]; then
		log_warn "verify_task_deliverables: PR #$pr_number does not reference $task_id — rejecting (cross-contamination guard)"
		return 1
	fi

	# Check PR is actually merged
	local pr_state
	if ! pr_state=$(gh pr view "$pr_number" --repo "$repo_slug" --json state --jq '.state' 2>>"$SUPERVISOR_LOG"); then
		log_warn "Failed to fetch PR state for $task_id (#$pr_number)"
		return 1
	fi
	if [[ "$pr_state" != "MERGED" ]]; then
		log_warn "PR #$pr_number for $task_id is not merged (state: ${pr_state:-unknown})"
		return 1
	fi

	# Check PR has substantive file changes (not just TODO.md or planning files)
	local changed_files
	if ! changed_files=$(gh pr view "$pr_number" --repo "$repo_slug" --json files --jq '.files[].path' 2>>"$SUPERVISOR_LOG"); then
		log_warn "Failed to fetch PR files for $task_id (#$pr_number)"
		return 1
	fi
	local substantive_files
	substantive_files=$(echo "$changed_files" | grep -vE '^(TODO\.md$|todo/|\.github/workflows/)' || true)

	# For planning tasks (#plan, #audit, #chore, #docs), planning-only PRs are valid deliverables (t261)
	if [[ -z "$substantive_files" ]]; then
		# Check if this is a planning task by looking for planning-related tags in TODO.md
		local task_line
		if [[ -n "$repo" ]] && [[ -f "$repo/TODO.md" ]]; then
			task_line=$(grep -E "^\s*- \[.\] $task_id\b" "$repo/TODO.md" || true)
			if [[ -n "$task_line" ]] && echo "$task_line" | grep -qE '#(plan|audit|chore|docs)\b'; then
				log_info "Task $task_id is a planning task — accepting planning-only PR #$pr_number"
				write_proof_log --task "$task_id" --event "deliverable_verified" --stage "complete" \
					--decision "verified:PR#$pr_number:planning-task" \
					--evidence "pr_state=$pr_state,planning_only=true,pr_number=$pr_number" \
					--maker "verify_task_deliverables" \
					--pr-url "$pr_url" 2>/dev/null || true
				return 0
			fi
		fi
		log_warn "PR #$pr_number for $task_id has no substantive file changes (only planning/workflow files)"
		return 1
	fi

	local file_count
	file_count=$(echo "$substantive_files" | wc -l | tr -d ' ')
	# Proof-log: deliverable verification passed (t218)
	write_proof_log --task "$task_id" --event "deliverable_verified" --stage "complete" \
		--decision "verified:PR#$pr_number" \
		--evidence "pr_state=$pr_state,file_count=$file_count,pr_number=$pr_number" \
		--maker "verify_task_deliverables" \
		--pr-url "$pr_url" 2>/dev/null || true
	log_info "Verified $task_id: PR #$pr_number merged with $file_count substantive file(s)"
	return 0
}

#######################################
# Populate VERIFY.md queue after PR merge (t180.2)
# Extracts changed files from the PR and generates check: directives
# based on file types (shellcheck for .sh, file-exists for new files, etc.)
# Appends a new entry to the VERIFY-QUEUE in todo/VERIFY.md
#
# Arguments:
#   $1 - task_id
#   $2 - pr_url (optional)
#   $3 - repo path (optional)
# Returns:
#   0 on success, 1 on failure
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
# Run verification checks for a task from VERIFY.md (t180.3)
# Parses the verify entry, executes each check: directive, and
# marks the entry as [x] (pass) or [!] (fail)
#
# Arguments:
#   $1 - task_id
#   $2 - repo path (optional)
# Returns:
#   0 if all checks pass, 1 if any fail
#######################################
run_verify_checks() {
	local task_id="$1"
	local repo="${2:-}"

	if [[ -z "$repo" ]]; then
		log_warn "run_verify_checks: no repo for $task_id"
		return 1
	fi

	local verify_file="$repo/todo/VERIFY.md"
	if [[ ! -f "$verify_file" ]]; then
		log_info "No VERIFY.md at $verify_file — nothing to verify"
		return 0
	fi

	# Find the verify entry for this task (pending entries only)
	local entry_line
	entry_line=$(grep -n "^- \[ \] v[0-9]* $task_id " "$verify_file" | head -1 || echo "")

	if [[ -z "$entry_line" ]]; then
		log_info "No pending verify entry for $task_id in VERIFY.md"
		return 0
	fi

	local line_num="${entry_line%%:*}"
	local verify_id
	verify_id=$(echo "$entry_line" | grep -oE 'v[0-9]+' | head -1 || echo "")

	log_info "Running verification checks for $task_id ($verify_id)..."

	# Extract check: directives from subsequent indented lines
	local checks=()
	local check_line=$((line_num + 1))
	local total_lines
	total_lines=$(wc -l <"$verify_file")

	while [[ "$check_line" -le "$total_lines" ]]; do
		local line
		line=$(sed -n "${check_line}p" "$verify_file")
		# Stop at next entry or blank line (entries are separated by blank lines)
		if [[ -z "$line" || "$line" =~ ^-\ \[ ]]; then
			break
		fi
		# Extract check: directives
		if [[ "$line" =~ ^[[:space:]]*check:[[:space:]]*(.*) ]]; then
			checks+=("${BASH_REMATCH[1]}")
		fi
		check_line=$((check_line + 1))
	done

	if [[ ${#checks[@]} -eq 0 ]]; then
		log_info "No check: directives found for $task_id — marking verified"
		mark_verify_entry "$verify_file" "$task_id" "pass" ""
		return 0
	fi

	local all_passed=true
	local failures=()

	for check_cmd in "${checks[@]}"; do
		local check_type="${check_cmd%% *}"
		local check_arg="${check_cmd#* }"

		log_info "  check: $check_cmd"

		case "$check_type" in
		file-exists)
			if [[ -f "$repo/$check_arg" ]]; then
				log_success "    PASS: $check_arg exists"
			else
				log_error "    FAIL: $check_arg not found"
				all_passed=false
				failures+=("file-exists: $check_arg not found")
			fi
			;;
		shellcheck)
			if command -v shellcheck &>/dev/null; then
				if shellcheck "$repo/$check_arg" 2>>"$SUPERVISOR_LOG"; then
					log_success "    PASS: shellcheck $check_arg"
				else
					log_error "    FAIL: shellcheck $check_arg"
					all_passed=false
					failures+=("shellcheck: $check_arg has violations")
				fi
			else
				log_warn "    SKIP: shellcheck not installed"
			fi
			;;
		rg)
			# rg "pattern" file — check pattern exists in file
			local rg_pattern rg_file
			# Parse: rg "pattern" file or rg 'pattern' file
			if [[ "$check_arg" =~ ^[\"\'](.+)[\"\'][[:space:]]+(.+)$ ]]; then
				rg_pattern="${BASH_REMATCH[1]}"
				rg_file="${BASH_REMATCH[2]}"
			else
				# Fallback: first word is pattern, rest is file
				rg_pattern="${check_arg%% *}"
				rg_file="${check_arg#* }"
			fi
			if rg -q "$rg_pattern" "$repo/$rg_file" 2>/dev/null; then
				log_success "    PASS: rg \"$rg_pattern\" $rg_file"
			else
				log_error "    FAIL: pattern \"$rg_pattern\" not found in $rg_file"
				all_passed=false
				failures+=("rg: \"$rg_pattern\" not found in $rg_file")
			fi
			;;
		bash)
			if (cd "$repo" && bash "$check_arg" 2>>"$SUPERVISOR_LOG"); then
				log_success "    PASS: bash $check_arg"
			else
				log_error "    FAIL: bash $check_arg"
				all_passed=false
				failures+=("bash: $check_arg failed")
			fi
			;;
		*)
			log_warn "    SKIP: unknown check type '$check_type'"
			;;
		esac
	done

	local today
	today=$(date +%Y-%m-%d)

	if [[ "$all_passed" == "true" ]]; then
		mark_verify_entry "$verify_file" "$task_id" "pass" "$today"
		# Proof-log: verification passed (t218)
		local _verify_duration
		_verify_duration=$(_proof_log_stage_duration "$task_id" "verifying")
		write_proof_log --task "$task_id" --event "verify_pass" --stage "verifying" \
			--decision "verified" \
			--evidence "checks=${#checks[@]},all_passed=true,verify_id=$verify_id" \
			--maker "run_verify_checks" \
			${_verify_duration:+--duration "$_verify_duration"} 2>/dev/null || true
		log_success "All verification checks passed for $task_id ($verify_id)"
		return 0
	else
		local failure_reason
		failure_reason=$(printf '%s; ' "${failures[@]}")
		failure_reason="${failure_reason%; }"
		mark_verify_entry "$verify_file" "$task_id" "fail" "$today" "$failure_reason"
		# Proof-log: verification failed (t218)
		local _verify_duration
		_verify_duration=$(_proof_log_stage_duration "$task_id" "verifying")
		write_proof_log --task "$task_id" --event "verify_fail" --stage "verifying" \
			--decision "verify_failed" \
			--evidence "checks=${#checks[@]},failures=${#failures[@]},reason=${failure_reason:0:200}" \
			--maker "run_verify_checks" \
			${_verify_duration:+--duration "$_verify_duration"} 2>/dev/null || true
		log_error "Verification failed for $task_id ($verify_id): $failure_reason"
		return 1
	fi
}

#######################################
# Mark a verify entry as passed [x] or failed [!] in VERIFY.md (t180.3)
#
# Arguments:
#   $1 - verify_file path
#   $2 - task_id
#   $3 - result ("pass" or "fail")
#   $4 - today (date, optional)
#   $5 - reason (for failures, optional)
# Returns:
#   0 always
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
#
# Arguments:
#   $1 - batch_id (optional, filters to batch tasks)
# Returns:
#   0 always
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

	while IFS='|' read -r tid trepo tpr; do
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
# Command: verify — manually run verification for a task (t180.3)
#
# Arguments:
#   $1 - task_id
# Returns:
#   0 if verification passed, 1 otherwise
#######################################
cmd_verify() {
	local task_id=""

	if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
		task_id="$1"
		shift
	fi

	if [[ -z "$task_id" ]]; then
		log_error "Usage: supervisor-helper.sh verify <task_id>"
		return 1
	fi

	ensure_db

	local escaped_id
	escaped_id=$(sql_escape "$task_id")
	local task_row
	task_row=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT status, repo, pr_url FROM tasks WHERE id = '$escaped_id';
    ")

	if [[ -z "$task_row" ]]; then
		log_error "Task not found: $task_id"
		return 1
	fi

	local tstatus trepo tpr
	IFS='|' read -r tstatus trepo tpr <<<"$task_row"

	# Allow verify from deployed or verify_failed states
	if [[ "$tstatus" != "deployed" && "$tstatus" != "verify_failed" ]]; then
		log_error "Task $task_id is in state '$tstatus' — must be 'deployed' or 'verify_failed' to verify"
		return 1
	fi

	cmd_transition "$task_id" "verifying" 2>>"$SUPERVISOR_LOG" || {
		log_error "Failed to transition $task_id to verifying"
		return 1
	}

	if run_verify_checks "$task_id" "$trepo"; then
		cmd_transition "$task_id" "verified" 2>>"$SUPERVISOR_LOG" || true
		log_success "Task $task_id: VERIFIED"

		# Commit and push VERIFY.md changes
		commit_verify_changes "$trepo" "$task_id" "pass" 2>>"$SUPERVISOR_LOG" || true
		return 0
	else
		cmd_transition "$task_id" "verify_failed" 2>>"$SUPERVISOR_LOG" || true
		log_error "Task $task_id: VERIFY FAILED"

		# Commit and push VERIFY.md changes
		commit_verify_changes "$trepo" "$task_id" "fail" 2>>"$SUPERVISOR_LOG" || true
		return 1
	fi
}

#######################################
# Commit and push VERIFY.md changes after verification (t180.3)
#
# Arguments:
#   $1 - repo path
#   $2 - task_id
#   $3 - result ("pass" or "fail")
# Returns:
#   0 on success, 1 on failure
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
