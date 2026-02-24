#!/usr/bin/env bash
# evaluate.sh - Worker evaluation support functions
#
# Helper functions for PR discovery, log analysis, failure classification,
# quality rating, and metadata recording. The actual evaluation logic lives
# in assess-task.sh (AI-powered, replaces the former evaluate_worker heuristic).
#
# t1312: Removed evaluate_worker() (687 lines), evaluate_with_ai() (251 lines),
# and evaluate_worker_with_metadata() (58 lines). Total: 774 lines of deterministic
# heuristics replaced by assess_task_with_metadata() in assess-task.sh.

#######################################
# Extract the last N lines from a log file (for AI eval context)
# Avoids sending entire multi-MB logs to the evaluator
#######################################
extract_log_tail() {
	local log_file="$1"
	local lines="${2:-200}"

	if [[ ! -f "$log_file" ]]; then
		echo "(no log file)"
		return 0
	fi

	tail -n "$lines" "$log_file" 2>/dev/null || echo "(failed to read log)"
	return 0
}

#######################################
# Extract structured outcome data from a log file
# Outputs key=value pairs for: pr_url, exit_code, signals, errors
#######################################
extract_log_metadata() {
	local log_file="$1"

	if [[ ! -f "$log_file" ]]; then
		echo "log_exists=false"
		return 0
	fi

	echo "log_exists=true"
	echo "log_bytes=$(wc -c <"$log_file" | tr -d ' ')"
	echo "log_lines=$(wc -l <"$log_file" | tr -d ' ')"

	# Content lines: exclude REPROMPT METADATA header (t198). Retry logs include
	# an 8-line metadata block that inflates log_lines, causing the backend error
	# threshold (< 10 lines) to miss short error-only logs. content_lines counts
	# only the actual worker output.
	local content_lines
	content_lines=$(grep -cv '^=== \(REPROMPT METADATA\|END REPROMPT METADATA\)\|^task_id=\|^timestamp=\|^retry=\|^work_dir=\|^previous_error=\|^fresh_worktree=' "$log_file" 2>/dev/null || echo 0)
	echo "content_lines=$content_lines"

	# Worker startup sentinel (t183)
	if grep -q 'WORKER_STARTED' "$log_file" 2>/dev/null; then
		echo "worker_started=true"
	else
		echo "worker_started=false"
	fi

	# Wrapper startup sentinel (t1190): distinguishes wrapper-never-ran from dispatch-exec-failed
	if grep -q 'WRAPPER_STARTED' "$log_file"; then
		echo "wrapper_started=true"
	else
		echo "wrapper_started=false"
	fi

	# Dispatch error sentinel (t183)
	if grep -q 'WORKER_DISPATCH_ERROR\|WORKER_FAILED' "$log_file" 2>/dev/null; then
		local dispatch_error
		dispatch_error=$(grep -o 'WORKER_DISPATCH_ERROR:.*\|WORKER_FAILED:.*' "$log_file" 2>/dev/null | head -1 | head -c 200 || echo "")
		echo "dispatch_error=${dispatch_error:-unknown}"
	else
		echo "dispatch_error="
	fi

	# Completion signals (t1008: added VERIFY_* signals for verify-mode workers)
	if grep -q 'FULL_LOOP_COMPLETE' "$log_file" 2>/dev/null; then
		echo "signal=FULL_LOOP_COMPLETE"
	elif grep -q 'VERIFY_COMPLETE' "$log_file" 2>/dev/null; then
		echo "signal=VERIFY_COMPLETE"
	elif grep -q 'VERIFY_INCOMPLETE' "$log_file" 2>/dev/null; then
		echo "signal=VERIFY_INCOMPLETE"
	elif grep -q 'VERIFY_NOT_STARTED' "$log_file" 2>/dev/null; then
		echo "signal=VERIFY_NOT_STARTED"
	elif grep -q 'TASK_COMPLETE' "$log_file" 2>/dev/null; then
		echo "signal=TASK_COMPLETE"
	else
		echo "signal=none"
	fi

	# PR URL extraction (t192): Extract from the worker's FINAL text output only.
	# Full-log grep is unsafe (t151) — memory recalls, TODO reads, and git log
	# embed PR URLs from other tasks. But the last "type":"text" JSON entry is
	# the worker's own summary and is authoritative. This eliminates the race
	# condition where gh pr list --head (in evaluate_worker) misses a just-created
	# PR, causing false clean_exit_no_signal retries.
	# Fallback: gh pr list --head in evaluate_worker() remains as a safety net.
	local final_pr_url=""
	local last_text_line
	last_text_line=$(grep '"type":"text"' "$log_file" 2>/dev/null | tail -1 || true)
	if [[ -n "$last_text_line" ]]; then
		final_pr_url=$(echo "$last_text_line" | grep -oE 'https://github\.com/[^/]+/[^/]+/pull/[0-9]+' | tail -1 || true)
	fi
	echo "pr_url=${final_pr_url}"

	# Task obsolete detection (t198): workers that determine a task is already
	# done or obsolete exit cleanly with no signal and no PR. Without this,
	# the supervisor retries them as clean_exit_no_signal, wasting retries.
	# Only check the final text entry (authoritative, same as PR URL extraction).
	local task_obsolete="false"
	if [[ -n "$last_text_line" ]] && echo "$last_text_line" | grep -qiE 'already done|already complete[d]?|task.*(obsolete|no longer needed)|no (changes|PR) needed|nothing to (change|fix|do)|no work (needed|required|to do)'; then
		task_obsolete="true"
	fi
	echo "task_obsolete=$task_obsolete"

	# Task tool parallelism tracking (t217): detect whether the worker used the
	# Task tool (mcp_task) to spawn sub-agents for parallel work. This is a
	# heuristic quality signal — workers that parallelise independent subtasks
	# are more efficient. Logged for pattern tracking and supervisor dashboards.
	local task_tool_count=0
	task_tool_count=$(grep -c 'mcp_task\|"tool_name":"task"\|"name":"task"' "$log_file" 2>/dev/null || true)
	task_tool_count="${task_tool_count//[^0-9]/}"
	task_tool_count="${task_tool_count:-0}"
	echo "task_tool_count=$task_tool_count"

	# Exit code
	local exit_line
	exit_line=$(grep '^EXIT:' "$log_file" 2>/dev/null | tail -1 || true)
	echo "exit_code=${exit_line#EXIT:}"

	# Error patterns - search only the LAST 20 lines to avoid false positives
	# from generated content. Worker logs (opencode JSON) embed tool outputs
	# that may discuss auth, errors, conflicts as documentation content.
	# Only the final lines contain actual execution status/errors.
	local log_tail_file
	log_tail_file=$(mktemp)
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "rm -f '${log_tail_file}'"
	tail -20 "$log_file" >"$log_tail_file" 2>/dev/null || true

	local rate_limit_count=0 auth_error_count=0 conflict_count=0 timeout_count=0 oom_count=0
	rate_limit_count=$(grep -ci 'rate.limit\|429\|too many requests' "$log_tail_file" 2>/dev/null || echo 0)
	auth_error_count=$(grep -ci 'permission denied\|unauthorized\|403\|401' "$log_tail_file" 2>/dev/null || echo 0)
	conflict_count=$(grep -ci 'merge conflict\|CONFLICT\|conflict marker' "$log_tail_file" 2>/dev/null || echo 0)
	timeout_count=$(grep -ci 'timeout\|timed out\|ETIMEDOUT' "$log_tail_file" 2>/dev/null || echo 0)
	oom_count=$(grep -ci 'out of memory\|OOM\|heap.*exceeded\|ENOMEM' "$log_tail_file" 2>/dev/null || echo 0)

	# Backend infrastructure errors - search tail only (same as other heuristics).
	# Full-log search caused false positives: worker logs embed tool output that
	# discusses errors, APIs, status codes as documentation content.
	# Anchored patterns prevent substring matches (e.g., 503 in timestamps).
	local backend_error_count=0
	backend_error_count=$(grep -ci 'endpoints failed\|gateway[[:space:]].*error\|service unavailable\|HTTP 503\|503 Service\|"status":[[:space:]]*503\|Quota protection\|over[_ -]\{0,1\}usage\|quota reset\|CreditsError\|Insufficient balance\|statusCode.*401' "$log_tail_file" 2>/dev/null || echo 0)

	rm -f "$log_tail_file"

	echo "rate_limit_count=$rate_limit_count"
	echo "auth_error_count=$auth_error_count"
	echo "conflict_count=$conflict_count"
	echo "timeout_count=$timeout_count"
	echo "oom_count=$oom_count"
	echo "backend_error_count=$backend_error_count"

	# JSON parse errors (opencode --format json output)
	if grep -q '"error"' "$log_file" 2>/dev/null; then
		local json_error
		json_error=$(grep -o '"error"[[:space:]]*:[[:space:]]*"[^"]*"' "$log_file" 2>/dev/null | tail -1 || true)
		echo "json_error=${json_error:-}"
	fi

	return 0
}

#######################################
# Validate that a PR belongs to a task by checking title/branch for task ID (t195)
#
# Prevents false attribution: a PR found via branch lookup must contain the
# task ID in its title or head branch name. Without this, stale branches or
# reused branch names could cause the supervisor to attribute an unrelated PR
# to a task, triggering false completion cascades (TODO.md [x] → GH issue close).
#
# $1: task_id (e.g., "t195")
# $2: repo_slug (e.g., "owner/repo")
# $3: pr_url (the candidate PR URL to validate)
#
# Returns 0 if PR belongs to task, 1 if not
# Outputs validated PR URL to stdout on success (empty on failure)
#######################################
validate_pr_belongs_to_task() {
	local task_id="$1"
	local repo_slug="$2"
	local pr_url="$3"

	if [[ -z "$pr_url" || -z "$task_id" || -z "$repo_slug" ]]; then
		return 1
	fi

	# Extract PR number from URL
	local pr_number
	pr_number=$(echo "$pr_url" | grep -oE '[0-9]+$' || echo "")
	if [[ -z "$pr_number" ]]; then
		return 1
	fi

	# Fetch PR title and head branch with retry + exponential backoff (t211).
	# GitHub API can fail transiently (rate limits, network blips, 502s).
	# 3 attempts: immediate, then 2s, then 4s delay.
	local pr_info="" attempt max_attempts=3 backoff=2
	for ((attempt = 1; attempt <= max_attempts; attempt++)); do
		pr_info=$(gh pr view "$pr_number" --repo "$repo_slug" \
			--json title,headRefName 2>>"${SUPERVISOR_LOG:-/dev/null}" || echo "")
		if [[ -n "$pr_info" ]]; then
			break
		fi
		if ((attempt < max_attempts)); then
			log_warn "validate_pr_belongs_to_task: attempt $attempt/$max_attempts failed for PR #$pr_number — retrying in ${backoff}s"
			sleep "$backoff"
			backoff=$((backoff * 2))
		fi
	done

	if [[ -z "$pr_info" ]]; then
		log_warn "validate_pr_belongs_to_task: cannot fetch PR #$pr_number for $task_id after $max_attempts attempts"
		return 1
	fi

	local pr_title pr_branch
	pr_title=$(echo "$pr_info" | jq -r '.title // ""' 2>/dev/null || echo "")
	pr_branch=$(echo "$pr_info" | jq -r '.headRefName // ""' 2>/dev/null || echo "")

	# Check if task ID appears in title or branch (case-insensitive).
	# Uses word boundary \b so "t195" matches "feature/t195", "(t195)",
	# "t195-fix-auth" but NOT "t1950" or "t1195".
	if echo "$pr_title" | grep -qi "\b${task_id}\b" 2>/dev/null; then
		echo "$pr_url"
		return 0
	fi

	if echo "$pr_branch" | grep -qi "\b${task_id}\b" 2>/dev/null; then
		echo "$pr_url"
		return 0
	fi

	log_warn "validate_pr_belongs_to_task: PR #$pr_number does not reference $task_id (title='$pr_title', branch='$pr_branch')"
	return 1
}

#######################################
# Parse a GitHub PR URL into repo_slug and pr_number (t232)
#
# Single source of truth for PR URL parsing. Replaces scattered
# grep -oE '[0-9]+$' and grep -oE 'github\.com/...' patterns.
#
# $1: pr_url (e.g., "https://github.com/owner/repo/pull/123")
#
# Outputs: "repo_slug|pr_number" on stdout (e.g., "owner/repo|123")
# Returns 0 on success, 1 if URL cannot be parsed
#######################################
parse_pr_url() {
	local pr_url="$1"

	if [[ -z "$pr_url" ]]; then
		return 1
	fi

	local pr_number
	pr_number=$(echo "$pr_url" | grep -oE '[0-9]+$' || echo "")
	if [[ -z "$pr_number" ]]; then
		return 1
	fi

	local repo_slug
	repo_slug=$(echo "$pr_url" | grep -oE 'github\.com/[^/]+/[^/]+' | sed 's|github\.com/||' || echo "")
	if [[ -z "$repo_slug" ]]; then
		return 1
	fi

	echo "${repo_slug}|${pr_number}"
	return 0
}

#######################################
# Discover a PR for a task via GitHub branch-name lookup (t232)
#
# Single source of truth for branch-based PR discovery. Tries:
#   1. The task's actual branch from the DB (worktree branch name)
#   2. Convention: feature/${task_id}
#
# All candidates are validated via validate_pr_belongs_to_task() before
# being returned. This prevents cross-contamination (t195, t223).
#
# $1: task_id (e.g., "t195")
# $2: repo_slug (e.g., "owner/repo")
# $3: task_branch (optional — the DB branch column; empty to skip)
#
# Outputs: validated PR URL on stdout (empty if none found)
# Returns 0 on success (URL found), 1 if no PR found
#######################################
discover_pr_by_branch() {
	local task_id="$1"
	local repo_slug="$2"
	local task_branch="${3:-}"

	if [[ -z "$task_id" || -z "$repo_slug" ]]; then
		return 1
	fi

	local candidate_pr_url=""

	# Try DB branch first (actual worktree branch name)
	if [[ -n "$task_branch" ]]; then
		candidate_pr_url=$(gh pr list --repo "$repo_slug" --head "$task_branch" --json url --jq '.[0].url' 2>>"${SUPERVISOR_LOG:-/dev/null}" || echo "")
	fi

	# Fallback to convention: feature/${task_id}
	if [[ -z "$candidate_pr_url" ]]; then
		candidate_pr_url=$(gh pr list --repo "$repo_slug" --head "feature/${task_id}" --json url --jq '.[0].url' 2>>"${SUPERVISOR_LOG:-/dev/null}" || echo "")
	fi

	if [[ -z "$candidate_pr_url" ]]; then
		return 1
	fi

	# Validate candidate PR contains task ID in title or branch (t195)
	local validated_url
	validated_url=$(validate_pr_belongs_to_task "$task_id" "$repo_slug" "$candidate_pr_url") || validated_url=""

	if [[ -n "$validated_url" ]]; then
		echo "$validated_url"
		return 0
	fi

	log_warn "discover_pr_by_branch: candidate PR for $task_id failed task ID validation — ignoring"
	return 1
}

#######################################
# Auto-create a PR for a task's orphaned branch (t247.2)
#
# When a worker exits with commits on its branch but no PR (e.g., context
# exhaustion before gh pr create), the supervisor creates the PR on its
# behalf instead of retrying. This saves ~300s per retry cycle.
#
# Prerequisites:
#   - Branch has commits ahead of base (caller verified)
#   - No existing PR for this branch (caller verified)
#   - gh CLI available and authenticated
#
# Steps:
#   1. Push branch to remote if not already pushed
#   2. Create a draft PR via gh pr create
#   3. Persist PR URL to DB via link_pr_to_task()
#
# $1: task_id
# $2: repo_path (local filesystem path to the repo/worktree)
# $3: branch_name
# $4: repo_slug (owner/repo)
#
# Outputs: PR URL on stdout if created, empty if failed
# Returns: 0 if PR created, 1 if failed
#######################################
auto_create_pr_for_task() {
	local task_id="$1"
	local repo_path="$2"
	local branch_name="$3"
	local repo_slug="$4"

	if [[ -z "$task_id" || -z "$repo_path" || -z "$branch_name" || -z "$repo_slug" ]]; then
		log_warn "auto_create_pr_for_task: missing required arguments (task=$task_id repo=$repo_path branch=$branch_name slug=$repo_slug)"
		return 1
	fi

	if ! command -v gh &>/dev/null; then
		log_warn "auto_create_pr_for_task: gh CLI not available — cannot create PR for $task_id"
		return 1
	fi

	# Fetch task description for PR title/body
	local escaped_id
	escaped_id=$(sql_escape "$task_id")
	local task_desc
	task_desc=$(db "$SUPERVISOR_DB" "SELECT description FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")
	if [[ -z "$task_desc" ]]; then
		task_desc="Worker task $task_id"
	fi

	# Determine base branch
	local base_branch
	base_branch=$(git -C "$repo_path" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || echo "main")

	# Ensure branch is pushed to remote
	local remote_branch_exists
	remote_branch_exists=$(git -C "$repo_path" ls-remote --heads origin "$branch_name" 2>/dev/null | head -1 || echo "")
	if [[ -z "$remote_branch_exists" ]]; then
		log_info "auto_create_pr_for_task: pushing $branch_name to origin for $task_id"
		if ! git -C "$repo_path" push -u origin "$branch_name" 2>>"${SUPERVISOR_LOG:-/dev/null}"; then
			log_warn "auto_create_pr_for_task: failed to push $branch_name for $task_id"
			return 1
		fi
	fi

	# Build commit summary for PR body (last 10 commits on branch)
	local commit_log
	commit_log=$(git -C "$repo_path" log --oneline "${base_branch}..${branch_name}" 2>/dev/null | head -10 || echo "(no commits)")

	# t288: Look up GitHub issue ref from TODO.md for cross-referencing
	local gh_issue_ref=""
	local todo_file="$repo_path/TODO.md"
	if [[ -f "$todo_file" ]]; then
		gh_issue_ref=$(grep -E "^\s*- \[.\] ${task_id} " "$todo_file" 2>/dev/null |
			head -1 | grep -oE 'ref:GH#[0-9]+' | head -1 | sed 's/ref:GH#//' || true)
	fi

	# Build issue reference line for PR body
	local issue_ref_line=""
	if [[ -n "$gh_issue_ref" ]]; then
		issue_ref_line="

Ref #${gh_issue_ref}"
	fi

	# Create draft PR
	local pr_body
	pr_body="## Auto-created by supervisor (t247.2)

Worker session ended with commits on branch but no PR (likely context exhaustion).
Supervisor auto-created this PR to preserve work and enable review.

### Commits

\`\`\`
${commit_log}
\`\`\`

### Task

${task_desc}${issue_ref_line}"

	local pr_url
	pr_url=$(gh pr create \
		--repo "$repo_slug" \
		--head "$branch_name" \
		--base "$base_branch" \
		--title "${task_id}: ${task_desc}" \
		--body "$pr_body" \
		--draft 2>>"${SUPERVISOR_LOG:-/dev/null}") || pr_url=""

	if [[ -z "$pr_url" ]]; then
		log_warn "auto_create_pr_for_task: gh pr create failed for $task_id ($branch_name)"
		return 1
	fi

	log_success "auto_create_pr_for_task: created draft PR for $task_id: $pr_url"

	# Persist via centralized link_pr_to_task (t232)
	link_pr_to_task "$task_id" --url "$pr_url" --caller "auto_create_pr" 2>>"${SUPERVISOR_LOG:-/dev/null}" || true

	echo "$pr_url"
	return 0
}

#######################################
# Link a PR to a task — single source of truth (t232)
#
# Centralizes the full discover-validate-persist pipeline for PR-to-task
# linking. Replaces scattered inline patterns across evaluate_worker(),
# check_pr_status(), scan_orphaned_prs(), scan_orphaned_pr_for_task(),
# and cmd_pr_lifecycle().
#
# Modes:
#   1. With --url: validate and persist a known PR URL
#   2. Without --url: discover PR via branch lookup, validate, persist
#
# Options:
#   --url <pr_url>     Candidate PR URL to validate and link
#   --transition       Also transition the task to complete (for orphan scans)
#   --notify           Send task notification after linking
#   --caller <name>    Caller name for log messages (default: "link_pr_to_task")
#
# $1: task_id
#
# Outputs: validated PR URL on stdout (empty if none found/linked)
# Returns 0 if PR was linked, 1 if no PR found/validated
#######################################
link_pr_to_task() {
	local task_id=""
	local candidate_url=""
	local do_transition="false"
	local do_notify="false"
	local caller="link_pr_to_task"

	# Parse arguments
	if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
		task_id="$1"
		shift
	fi

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--url)
			[[ $# -lt 2 ]] && {
				log_error "--url requires a value"
				return 1
			}
			candidate_url="$2"
			shift 2
			;;
		--transition)
			do_transition="true"
			shift
			;;
		--notify)
			do_notify="true"
			shift
			;;
		--caller)
			[[ $# -lt 2 ]] && {
				log_error "--caller requires a value"
				return 1
			}
			caller="$2"
			shift 2
			;;
		*)
			log_error "link_pr_to_task: unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$task_id" ]]; then
		log_error "link_pr_to_task: task_id required"
		return 1
	fi

	ensure_db

	local escaped_id
	escaped_id=$(sql_escape "$task_id")

	# Fetch task details from DB
	local task_row
	task_row=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT status, repo, branch, pr_url FROM tasks
        WHERE id = '$escaped_id';
    " 2>/dev/null || echo "")

	if [[ -z "$task_row" ]]; then
		log_error "$caller: task not found: $task_id"
		return 1
	fi

	local tstatus trepo tbranch tpr_url
	IFS='|' read -r tstatus trepo tbranch tpr_url <<<"$task_row"

	# If a candidate URL was provided, validate and persist it
	if [[ -n "$candidate_url" ]]; then
		# Resolve repo slug for validation
		local repo_slug=""
		if [[ -n "$trepo" ]]; then
			repo_slug=$(detect_repo_slug "$trepo" 2>/dev/null || echo "")
		fi

		if [[ -z "$repo_slug" ]]; then
			log_warn "$caller: cannot validate PR URL for $task_id (repo slug detection failed) — clearing to prevent cross-contamination"
			return 1
		fi

		local validated_url
		validated_url=$(validate_pr_belongs_to_task "$task_id" "$repo_slug" "$candidate_url") || validated_url=""

		if [[ -z "$validated_url" ]]; then
			log_warn "$caller: PR URL for $task_id failed task ID validation — not linking"
			return 1
		fi

		# Persist to DB
		db "$SUPERVISOR_DB" "UPDATE tasks SET pr_url = '$(sql_escape "$validated_url")' WHERE id = '$escaped_id';" 2>/dev/null || {
			log_warn "$caller: failed to persist PR URL for $task_id"
			return 1
		}

		# Transition if requested (for orphan scan use cases)
		if [[ "$do_transition" == "true" ]]; then
			case "$tstatus" in
			failed | blocked | retrying)
				log_info "  $caller: PR found for $task_id ($tstatus -> complete): $validated_url"
				cmd_transition "$task_id" "complete" --pr-url "$validated_url" 2>>"${SUPERVISOR_LOG:-/dev/null}" || true
				update_todo_on_complete "$task_id" 2>>"${SUPERVISOR_LOG:-/dev/null}" || true
				;;
			complete)
				log_info "  $caller: linked PR to completed task $task_id: $validated_url"
				;;
			*)
				log_info "  $caller: linked PR to $task_id ($tstatus): $validated_url"
				;;
			esac
		fi

		# Notify if requested
		if [[ "$do_notify" == "true" ]]; then
			send_task_notification "$task_id" "complete" "pr_linked:$validated_url" 2>>"${SUPERVISOR_LOG:-/dev/null}" || true
			local tid_desc
			tid_desc=$(db "$SUPERVISOR_DB" "SELECT description FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")
			store_success_pattern "$task_id" "pr_linked_${caller}" "$tid_desc" 2>>"${SUPERVISOR_LOG:-/dev/null}" || true
		fi

		echo "$validated_url"
		return 0
	fi

	# No candidate URL — discover via branch lookup
	# Skip if PR already linked
	if [[ -n "$tpr_url" && "$tpr_url" != "no_pr" && "$tpr_url" != "task_only" && "$tpr_url" != "task_obsolete" && "$tpr_url" != "" ]]; then
		echo "$tpr_url"
		return 0
	fi

	# Need a repo to discover
	if [[ -z "$trepo" ]]; then
		return 1
	fi

	local repo_slug
	repo_slug=$(detect_repo_slug "$trepo" 2>/dev/null || echo "")
	if [[ -z "$repo_slug" ]]; then
		return 1
	fi

	# Discover via branch lookup
	local discovered_url
	discovered_url=$(discover_pr_by_branch "$task_id" "$repo_slug" "$tbranch") || discovered_url=""

	if [[ -z "$discovered_url" ]]; then
		return 1
	fi

	# Persist to DB
	db "$SUPERVISOR_DB" "UPDATE tasks SET pr_url = '$(sql_escape "$discovered_url")' WHERE id = '$escaped_id';" 2>/dev/null || {
		log_warn "$caller: failed to persist discovered PR URL for $task_id"
		return 1
	}

	# Transition if requested
	if [[ "$do_transition" == "true" ]]; then
		case "$tstatus" in
		failed | blocked | retrying)
			log_info "  $caller: discovered PR for $task_id ($tstatus -> complete): $discovered_url"
			cmd_transition "$task_id" "complete" --pr-url "$discovered_url" 2>>"${SUPERVISOR_LOG:-/dev/null}" || true
			update_todo_on_complete "$task_id" 2>>"${SUPERVISOR_LOG:-/dev/null}" || true
			;;
		complete)
			log_info "  $caller: linked discovered PR to completed task $task_id: $discovered_url"
			;;
		*)
			log_info "  $caller: linked discovered PR to $task_id ($tstatus): $discovered_url"
			;;
		esac
	fi

	# Notify if requested
	if [[ "$do_notify" == "true" ]]; then
		send_task_notification "$task_id" "complete" "pr_discovered:$discovered_url" 2>>"${SUPERVISOR_LOG:-/dev/null}" || true
		local tid_desc
		tid_desc=$(db "$SUPERVISOR_DB" "SELECT description FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")
		store_success_pattern "$task_id" "pr_discovered_${caller}" "$tid_desc" 2>>"${SUPERVISOR_LOG:-/dev/null}" || true
	fi

	echo "$discovered_url"
	return 0
}

#######################################
# Classify a failure outcome_detail string into a failure mode category (t1096)
#
# Maps the granular outcome_detail strings from evaluate_worker() into
# five broad categories for pattern tracking and model routing decisions.
#
# Categories:
#   TRANSIENT   - recoverable with retry (rate limits, timeouts, backend blips)
#   RESOURCE    - infrastructure/environment issue (auth, OOM, disk)
#   ENVIRONMENT - dispatch infrastructure failure (t1113: CLI missing, worker never
#                 started, log file missing). These are NOT task/code problems —
#                 retrying won't help until the environment is fixed. The pulse
#                 handles these by deferring re-queue without burning retry count.
#   LOGIC       - task/code problem (merge conflict, test failure, build error)
#   BLOCKED     - external dependency (human needed, upstream, missing context)
#   AMBIGUOUS   - unclear cause (clean exit, max retries, unknown)
#
# $1: outcome_detail (e.g., "rate_limited", "auth_error", "merge_conflict")
#
# Outputs: category string on stdout
# Returns: 0 always
#######################################
classify_failure_mode() {
	local detail="$1"

	case "$detail" in
	rate_limited | backend_quota_error | backend_infrastructure_error | \
		retry:backend* | quota* | 429* | \
		timeout | interrupted_sigint | killed_sigkill | terminated_sigterm | \
		work_in_progress)
		echo "TRANSIENT"
		;;
	auth_error | unauthorized | forbidden | 401* | 403* | \
		billing_credits_exhausted | out_of_memory)
		echo "RESOURCE"
		;;
	worker_never_started* | log_file_missing* | log_file_empty | \
		no_log_path_in_db* | dispatch_script_not_executable)
		# t1113: Reclassified from LOGIC to ENVIRONMENT. These failures indicate
		# the dispatch infrastructure (CLI binary, worktree, permissions) is broken,
		# not the task itself. Retrying the task won't help — the environment must
		# be fixed first. The pulse defers these without burning retry count.
		echo "ENVIRONMENT"
		;;
	merge_conflict | test_fail* | lint_* | build_*)
		echo "LOGIC"
		;;
	blocked:* | waiting* | upstream* | missing_context* | \
		verify_incomplete_no_pr | verify_not_started_needs_full)
		echo "BLOCKED"
		;;
	clean_exit_no_signal | max_retries | \
		ambiguous_skipped_ai | ambiguous_ai_unavailable | ambiguous* | "")
		echo "AMBIGUOUS"
		;;
	*)
		echo "AMBIGUOUS"
		;;
	esac
	return 0
}

#######################################
# Rate the output quality of a worker based on outcome type (t1096)
#
# Derives a 3-point quality score from the outcome type without an extra
# AI call. Only AMBIGUOUS failure modes trigger AI quality assessment.
#
# Scale:
#   0 = no_output    - worker produced nothing usable
#   1 = partial      - some progress, incomplete or broken artifact
#   2 = complete     - deliverable matches task intent
#
# $1: outcome_type (complete|retry|blocked|failed)
# $2: outcome_detail (for context)
#
# Outputs: quality score (0, 1, or 2) on stdout
# Returns: 0 always
#######################################
rate_output_quality() {
	local outcome_type="$1"
	local outcome_detail="${2:-}"

	case "$outcome_type" in
	complete)
		# task_obsolete = task was already done, still counts as complete
		echo "2"
		;;
	retry)
		# All retries imply some form of progress or attempt
		echo "1"
		;;
	blocked)
		# auth/billing blocks = no output; merge conflict = partial
		case "$outcome_detail" in
		auth_error | billing_credits_exhausted | out_of_memory)
			echo "0"
			;;
		merge_conflict)
			echo "1"
			;;
		*)
			echo "0"
			;;
		esac
		;;
	failed)
		# All failed outcomes are considered to have no usable output
		echo "0"
		;;
	*)
		echo "0"
		;;
	esac
	return 0
}

#######################################
# Record evaluation metadata to pattern tracker (t1096)
#
# Called after evaluate_worker() resolves a verdict. Stores richer metadata
# than the basic store_success/failure_pattern calls: failure mode category,
# output quality score, AI eval flag, and log quality signals.
#
# $1: task_id
# $2: outcome_type (complete|retry|blocked|failed)
# $3: outcome_detail
# $4: failure_mode (TRANSIENT|RESOURCE|LOGIC|BLOCKED|AMBIGUOUS|NONE)
# $5: quality_score (0|1|2)
# $6: ai_evaluated (true|false) — whether AI eval was used
#
# Returns: 0 always (non-blocking)
#######################################
record_evaluation_metadata() {
	local task_id="$1"
	local outcome_type="$2"
	local outcome_detail="$3"
	local failure_mode="${4:-AMBIGUOUS}"
	local quality_score="${5:-0}"
	local ai_evaluated="${6:-false}"

	local pattern_helper="${SCRIPT_DIR}/pattern-tracker-helper.sh"
	if [[ ! -x "$pattern_helper" ]]; then
		pattern_helper="$HOME/.aidevops/agents/scripts/pattern-tracker-helper.sh"
	fi
	if [[ ! -x "$pattern_helper" ]]; then
		return 0
	fi

	# Map outcome_type to pattern-tracker outcome
	local pt_outcome="failure"
	[[ "$outcome_type" == "complete" ]] && pt_outcome="success"

	# Build extra tags for new fields
	local extra_tags="failure_mode:${failure_mode},quality:${quality_score}"
	[[ "$ai_evaluated" == "true" ]] && extra_tags="${extra_tags},ai_eval:true"

	# Look up model tier, requested_tier, actual_tier, and log_file from DB (t1117)
	local model_tier="" requested_tier="" actual_tier="" task_log_file=""
	if [[ -n "${SUPERVISOR_DB:-}" ]]; then
		local task_row
		task_row=$(db -separator '|' "$SUPERVISOR_DB" \
			"SELECT model, requested_tier, actual_tier, log_file FROM tasks WHERE id = '$(sql_escape "$task_id")';" \
			2>/dev/null || echo "")
		if [[ -n "$task_row" ]]; then
			local task_model
			IFS='|' read -r task_model requested_tier actual_tier task_log_file <<<"$task_row"
			if [[ -n "$task_model" ]] && command -v model_to_tier &>/dev/null; then
				model_tier=$(model_to_tier "$task_model" 2>/dev/null || echo "")
			fi
			# Fall back to actual_tier if model_to_tier unavailable
			[[ -z "$model_tier" && -n "$actual_tier" ]] && model_tier="$actual_tier"
		fi
	fi

	# Extract token counts from worker log for cost tracking (t1114, t1117)
	# Supports camelCase (opencode JSON) and snake_case (claude CLI JSON) formats.
	local tokens_in="" tokens_out=""
	if [[ -n "$task_log_file" && -f "$task_log_file" ]]; then
		local raw_in raw_out
		raw_in=$(grep -oE '"inputTokens":[0-9]+' "$task_log_file" 2>/dev/null | tail -1 | grep -oE '[0-9]+' || true)
		raw_out=$(grep -oE '"outputTokens":[0-9]+' "$task_log_file" 2>/dev/null | tail -1 | grep -oE '[0-9]+' || true)
		if [[ -z "$raw_in" ]]; then
			raw_in=$(grep -oE '"input_tokens":[0-9]+' "$task_log_file" 2>/dev/null | tail -1 | grep -oE '[0-9]+' || true)
		fi
		if [[ -z "$raw_out" ]]; then
			raw_out=$(grep -oE '"output_tokens":[0-9]+' "$task_log_file" 2>/dev/null | tail -1 | grep -oE '[0-9]+' || true)
		fi
		[[ -n "$raw_in" ]] && tokens_in="$raw_in"
		[[ -n "$raw_out" ]] && tokens_out="$raw_out"
	fi

	# Look up task type from DB tags if available, fallback to "unknown"
	# TODO(t1096): extract real task type from TODO.md tags or DB metadata
	local task_type="unknown"
	if [[ -n "${SUPERVISOR_DB:-}" ]]; then
		local task_desc
		task_desc=$(db "$SUPERVISOR_DB" "SELECT description FROM tasks WHERE id = '$(sql_escape "$task_id")';" 2>/dev/null || echo "")
		# Infer type from description keywords (best-effort)
		case "$task_desc" in
		*bugfix* | *fix* | *bug*) task_type="bugfix" ;;
		*refactor*) task_type="refactor" ;;
		*test*) task_type="testing" ;;
		*doc*) task_type="docs" ;;
		*) task_type="feature" ;;
		esac
	fi

	# Build tier delta tag for cost analysis (t1117, t1114, t1109)
	# Captures whether the actual dispatch tier matched what was requested.
	local tier_delta_tag=""
	if [[ -n "$requested_tier" && -n "$actual_tier" && "$requested_tier" != "$actual_tier" ]]; then
		tier_delta_tag=",tier_delta:${requested_tier}->${actual_tier}"
	fi

	# t1252: Look up eval_duration_secs from DB for inclusion in pattern record
	local eval_duration_secs=""
	if [[ -n "${SUPERVISOR_DB:-}" ]]; then
		eval_duration_secs=$(db "$SUPERVISOR_DB" "SELECT eval_duration_secs FROM tasks WHERE id = '$(sql_escape "$task_id")';" 2>/dev/null || echo "")
	fi

	# Build description
	local description="Worker $task_id: ${outcome_type}:${outcome_detail} [fmode:${failure_mode}] [quality:${quality_score}]"
	[[ -n "$requested_tier" ]] && description="${description} [req:${requested_tier}]"
	[[ -n "$actual_tier" ]] && description="${description} [act:${actual_tier}]"
	[[ -n "$tokens_in" || -n "$tokens_out" ]] && description="${description} [tokens:${tokens_in:-0}+${tokens_out:-0}]"
	[[ -n "$eval_duration_secs" ]] && description="${description} [eval:${eval_duration_secs}s]"

	# Build record args — add tier and token counts when available (t1114, t1117)
	local record_args=(
		--outcome "$pt_outcome"
		--task-type "$task_type"
		--task-id "$task_id"
		--description "$description"
		--tags "supervisor,evaluate,${outcome_type},${extra_tags}${model_tier:+,model:${model_tier}}${requested_tier:+,requested_tier:${requested_tier}}${actual_tier:+,actual_tier:${actual_tier}}${tier_delta_tag}${eval_duration_secs:+,eval_duration:${eval_duration_secs}s}"
	)
	[[ -n "$model_tier" ]] && record_args+=(--model "$model_tier")
	[[ -n "$tokens_in" ]] && record_args+=(--tokens-in "$tokens_in")
	[[ -n "$tokens_out" ]] && record_args+=(--tokens-out "$tokens_out")

	"$pattern_helper" record "${record_args[@]}" 2>/dev/null || true

	# Record tier delta to budget-tracker for cost analysis (t1191)
	# Only records when we have token data AND tier information, so the
	# budget-tracker can calculate the cost difference between tiers.
	if [[ -n "$tokens_in" || -n "$tokens_out" ]] && [[ -n "$actual_tier" ]]; then
		local budget_helper="${SCRIPT_DIR}/../budget-tracker-helper.sh"
		if [[ ! -x "$budget_helper" ]]; then
			budget_helper="$HOME/.aidevops/agents/scripts/budget-tracker-helper.sh"
		fi
		if [[ -x "$budget_helper" ]]; then
			# Look up the model string from DB for accurate cost calculation
			local budget_model=""
			if [[ -n "${SUPERVISOR_DB:-}" ]]; then
				budget_model=$(db "$SUPERVISOR_DB" "SELECT model FROM tasks WHERE id = '$(sql_escape "$task_id")';" 2>/dev/null || echo "")
			fi
			[[ -z "$budget_model" ]] && budget_model="anthropic/claude-${actual_tier}-4"

			local budget_provider="${budget_model%%/*}"
			[[ -z "$budget_provider" ]] && budget_provider="anthropic"

			local budget_args=(
				--provider "$budget_provider"
				--model "$budget_model"
				--tier "$actual_tier"
				--task "$task_id"
			)
			[[ -n "$tokens_in" ]] && budget_args+=(--input-tokens "$tokens_in")
			[[ -n "$tokens_out" ]] && budget_args+=(--output-tokens "$tokens_out")
			[[ -n "$requested_tier" ]] && budget_args+=(--requested-tier "$requested_tier")
			[[ -n "$actual_tier" ]] && budget_args+=(--actual-tier "$actual_tier")

			"$budget_helper" record "${budget_args[@]}" 2>/dev/null || true
		fi
	fi

	return 0
}

#######################################
cmd_evaluate() {
	local task_id=""

	if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
		task_id="$1"
		shift
	fi

	# t1312: --no-ai flag removed (evaluation is always AI-powered now)
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--no-ai)
			log_warn "--no-ai is deprecated (evaluation is always AI-powered, t1312)"
			shift
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$task_id" ]]; then
		log_error "Usage: supervisor-helper.sh evaluate <task_id>"
		return 1
	fi

	ensure_db

	# Show metadata first
	local escaped_id
	escaped_id=$(sql_escape "$task_id")
	local tlog
	tlog=$(db "$SUPERVISOR_DB" "SELECT log_file FROM tasks WHERE id = '$escaped_id';")

	if [[ -n "$tlog" && -f "$tlog" ]]; then
		echo -e "${BOLD}=== Log Metadata: $task_id ===${NC}"
		extract_log_metadata "$tlog"
		echo ""
	fi

	# Run evaluation via AI-powered assess_task (t1312: replaces evaluate_worker)
	echo -e "${BOLD}=== Evaluation Result ===${NC}"
	local outcome
	outcome=$(assess_task_with_metadata "$task_id")
	local outcome_type="${outcome%%:*}"
	local outcome_detail="${outcome#*:}"

	local color="$NC"
	case "$outcome_type" in
	complete) color="$GREEN" ;;
	retry) color="$YELLOW" ;;
	blocked) color="$RED" ;;
	failed) color="$RED" ;;
	esac

	echo -e "Verdict: ${color}${outcome_type}${NC}: $outcome_detail"
	return 0
}

#######################################
# Record worker spend in budget tracker (t1100)
# Extracts token usage from worker log (OpenCode JSON format) and records
# the spend event for budget-aware routing decisions.
#
# OpenCode JSON output includes usage data like:
#   "usage":{"input_tokens":50000,"output_tokens":10000}
# or in the session summary at the end of the log.
#
# Falls back to estimating from log size if no structured usage data found.
#######################################
record_worker_spend() {
	local task_id="$1"
	local model="${2:-}"

	local budget_helper="${SCRIPT_DIR}/../budget-tracker-helper.sh"
	if [[ ! -x "$budget_helper" ]]; then
		return 0
	fi

	ensure_db

	local escaped_id
	escaped_id=$(sql_escape "$task_id")
	local task_row
	task_row=$(db -separator '|' "$SUPERVISOR_DB" "
		SELECT log_file, model, repo, requested_tier, actual_tier FROM tasks WHERE id = '$escaped_id';
	" 2>/dev/null) || return 0

	if [[ -z "$task_row" ]]; then
		return 0
	fi

	local tlog tmodel trepo trequested_tier tactual_tier
	IFS='|' read -r tlog tmodel trepo trequested_tier tactual_tier <<<"$task_row"

	# Use task model if not passed
	model="${model:-$tmodel}"
	if [[ -z "$model" ]]; then
		return 0
	fi

	# Extract provider from model string
	local provider=""
	if [[ "$model" == *"/"* ]]; then
		provider="${model%%/*}"
	else
		provider="anthropic"
	fi

	# Determine tier from model name
	local tier=""
	case "$model" in
	*opus*) tier="opus" ;;
	*sonnet*) tier="sonnet" ;;
	*haiku*) tier="haiku" ;;
	*flash*) tier="flash" ;;
	*pro*) tier="pro" ;;
	*) tier="unknown" ;;
	esac

	local input_tokens=0 output_tokens=0

	# Try to extract token usage from log file
	if [[ -n "$tlog" && -f "$tlog" ]]; then
		# OpenCode JSON format: look for usage summary
		local usage_line
		usage_line=$(grep -o '"input_tokens":[0-9]*' "$tlog" 2>/dev/null | tail -1 || true)
		if [[ -n "$usage_line" ]]; then
			input_tokens=$(echo "$usage_line" | grep -o '[0-9]*' || echo "0")
		fi

		usage_line=$(grep -o '"output_tokens":[0-9]*' "$tlog" 2>/dev/null | tail -1 || true)
		if [[ -n "$usage_line" ]]; then
			output_tokens=$(echo "$usage_line" | grep -o '[0-9]*' || echo "0")
		fi

		# Fallback: estimate from log size if no structured data
		# Rough heuristic: 1 byte of log ~ 0.5 tokens (conservative)
		if [[ "$input_tokens" -eq 0 && "$output_tokens" -eq 0 ]]; then
			local log_size
			log_size=$(wc -c <"$tlog" 2>/dev/null | tr -d ' ')
			if [[ "$log_size" -gt 1000 ]]; then
				# Estimate: typical worker session uses ~50K input, ~10K output
				# Scale by log size relative to typical 100KB log
				local scale
				scale=$(awk "BEGIN { s = $log_size / 100000.0; if (s < 0.1) s = 0.1; if (s > 10) s = 10; printf \"%.2f\", s }")
				input_tokens=$(awk "BEGIN { printf \"%d\", 50000 * $scale }")
				output_tokens=$(awk "BEGIN { printf \"%d\", 10000 * $scale }")
			fi
		fi
	fi

	# Record the spend event
	if [[ "$input_tokens" -gt 0 || "$output_tokens" -gt 0 ]]; then
		"$budget_helper" record \
			--provider "$provider" \
			--model "$model" \
			--tier "$tier" \
			--task "$task_id" \
			--input-tokens "$input_tokens" \
			--output-tokens "$output_tokens" 2>/dev/null || true

		# Log tier delta for cost analysis (t1117): shows requested vs actual tier
		# alongside token counts so cost waste is immediately visible in logs.
		local tier_info="${provider}/${tier}"
		if [[ -n "$trequested_tier" && "$trequested_tier" != "$tactual_tier" ]]; then
			tier_info="${tier_info} [req:${trequested_tier}→act:${tactual_tier:-$tier}]"
		fi
		log_verbose "Budget: recorded spend for $task_id ($tier_info: ${input_tokens}in/${output_tokens}out)"
	fi

	return 0
}
