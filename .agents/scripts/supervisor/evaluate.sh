#!/usr/bin/env bash
# evaluate.sh - Worker outcome evaluation functions
#
# Functions for evaluating worker outcomes, PR discovery,
# and AI-assisted evaluation


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
	if [[ -n "$last_text_line" ]]; then
		if echo "$last_text_line" | grep -qiE 'already done|already complete[d]?|task.*(obsolete|no longer needed)|no (changes|PR) needed|nothing to (change|fix|do)|no work (needed|required|to do)'; then
			task_obsolete="true"
		fi
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
# Evaluate a completed worker's outcome using log analysis
# Returns: complete:<detail>, retry:<reason>, blocked:<reason>, failed:<reason>
#
# Four-tier evaluation:
#   1. Deterministic: check for known signals and error patterns
#   2. Heuristic: analyze exit codes and error counts
#   2.5. Git heuristic (t175): check commits on branch + uncommitted changes
#   3. AI eval: dispatch cheap Sonnet call for ambiguous outcomes
#######################################
evaluate_worker() {
	local task_id="$1"
	local skip_ai_eval="${2:-false}"

	ensure_db

	local escaped_id
	escaped_id=$(sql_escape "$task_id")
	local task_row
	task_row=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT status, log_file, retries, max_retries, session_id, pr_url
        FROM tasks WHERE id = '$escaped_id';
    ")

	if [[ -z "$task_row" ]]; then
		log_error "Task not found: $task_id"
		return 1
	fi

	local tstatus tlog tretries tmax_retries tsession tpr_url
	IFS='|' read -r tstatus tlog tretries tmax_retries tsession tpr_url <<<"$task_row"

	# Enhanced no_log_file diagnostics (t183)
	# Instead of a bare "failed:no_log_file", gather context about why the log
	# is missing so the supervisor can make better retry/block decisions and
	# self-healing diagnostics have actionable information.
	if [[ -z "$tlog" ]]; then
		# No log path in DB at all — dispatch likely failed before setting log_file
		local diag_detail="no_log_path_in_db"
		local pid_file="$SUPERVISOR_DIR/pids/${task_id}.pid"
		if [[ -f "$pid_file" ]]; then
			local stale_pid
			stale_pid=$(cat "$pid_file" 2>/dev/null || echo "")
			if [[ -n "$stale_pid" ]] && ! kill -0 "$stale_pid" 2>/dev/null; then
				diag_detail="no_log_path_in_db:worker_pid_${stale_pid}_dead"
			elif [[ -n "$stale_pid" ]]; then
				diag_detail="no_log_path_in_db:worker_pid_${stale_pid}_alive"
			fi
		fi
		echo "failed:${diag_detail}"
		return 0
	fi

	if [[ ! -f "$tlog" ]]; then
		# Log path set in DB but file doesn't exist — worker wrapper never ran
		local diag_detail="log_file_missing"
		local dispatch_script="${SUPERVISOR_DIR}/pids/${task_id}-dispatch.sh"
		local wrapper_script="${SUPERVISOR_DIR}/pids/${task_id}-wrapper.sh"
		if [[ ! -f "$dispatch_script" && ! -f "$wrapper_script" ]]; then
			diag_detail="log_file_missing:no_dispatch_scripts"
		elif [[ -f "$dispatch_script" && ! -x "$dispatch_script" ]]; then
			diag_detail="log_file_missing:dispatch_script_not_executable"
		fi
		local pid_file="$SUPERVISOR_DIR/pids/${task_id}.pid"
		if [[ -f "$pid_file" ]]; then
			local stale_pid
			stale_pid=$(cat "$pid_file" 2>/dev/null || echo "")
			if [[ -n "$stale_pid" ]] && ! kill -0 "$stale_pid" 2>/dev/null; then
				diag_detail="${diag_detail}:worker_pid_${stale_pid}_dead"
			fi
		else
			diag_detail="${diag_detail}:no_pid_file"
		fi
		echo "failed:${diag_detail}"
		return 0
	fi

	# Log file exists but may be empty or contain only metadata header (t183)
	local log_size
	log_size=$(wc -c <"$tlog" 2>/dev/null | tr -d ' ')
	if [[ "$log_size" -eq 0 ]]; then
		echo "failed:log_file_empty"
		return 0
	fi

	# Check if worker never started (only dispatch metadata, no WORKER_STARTED sentinel)
	if [[ "$log_size" -lt 500 ]] && ! grep -q 'WORKER_STARTED' "$tlog" 2>/dev/null; then
		# Log has metadata but worker never started — extract any error from log
		local startup_error=""
		startup_error=$(grep -i 'WORKER_FAILED\|WORKER_DISPATCH_ERROR\|command not found\|No such file\|Permission denied' "$tlog" 2>/dev/null | head -1 | head -c 200 || echo "")
		if [[ -n "$startup_error" ]]; then
			echo "failed:worker_never_started:$(echo "$startup_error" | tr ' ' '_' | tr -cd '[:alnum:]_:-')"
		else
			echo "failed:worker_never_started:no_sentinel"
		fi
		return 0
	fi

	# --- Tier 1: Deterministic signal detection ---

	# Parse structured metadata from log (bash 3.2 compatible - no associative arrays)
	local meta_output
	meta_output=$(extract_log_metadata "$tlog")

	# Helper: extract a value from key=value metadata output
	_meta_get() {
		local key="$1" default="${2:-}"
		local val
		val=$(echo "$meta_output" | grep "^${key}=" | head -1 | cut -d= -f2-)
		echo "${val:-$default}"
	}

	local meta_signal meta_pr_url meta_exit_code
	meta_signal=$(_meta_get "signal" "none")
	meta_pr_url=$(_meta_get "pr_url" "")
	meta_exit_code=$(_meta_get "exit_code" "")

	# Seed PR URL from DB (t171): check_pr_status() or a previous pulse may have
	# already found and persisted the PR URL. Use it before expensive gh API calls.
	if [[ -z "$meta_pr_url" && -n "${tpr_url:-}" && "$tpr_url" != "no_pr" && "$tpr_url" != "task_only" ]]; then
		meta_pr_url="$tpr_url"
	fi

	# Resolve repo slug early — needed for PR validation (t195) and fallback detection
	local task_repo task_branch repo_slug_detect
	task_repo=$(sqlite3 "$SUPERVISOR_DB" "SELECT repo FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")
	task_branch=$(sqlite3 "$SUPERVISOR_DB" "SELECT branch FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")
	repo_slug_detect=""
	if [[ -n "$task_repo" ]]; then
		repo_slug_detect=$(detect_repo_slug "$task_repo" 2>/dev/null || echo "")
	fi

	# Validate PR URL belongs to this task (t195, t223): a previous pulse
	# may have stored a PR URL that doesn't actually reference this task ID
	# (e.g., branch reuse, stale data, or log containing another task's PR URL).
	# Validate before using for attribution. If repo slug detection failed,
	# clear the PR URL entirely — unvalidated URLs cause cross-contamination
	# where the wrong PR gets linked to the wrong task (t223).
	if [[ -n "$meta_pr_url" ]]; then
		if [[ -n "$repo_slug_detect" ]]; then
			local validated_url
			validated_url=$(validate_pr_belongs_to_task "$task_id" "$repo_slug_detect" "$meta_pr_url") || validated_url=""
			if [[ -z "$validated_url" ]]; then
				log_warn "evaluate_worker: PR URL for $task_id failed task ID validation — clearing"
				meta_pr_url=""
			fi
		else
			log_warn "evaluate_worker: cannot validate PR URL for $task_id (repo slug detection failed) — clearing to prevent cross-contamination"
			meta_pr_url=""
		fi
	fi

	# Fallback PR URL detection via centralized discover_pr_by_branch() (t232, t161, t195)
	if [[ -z "$meta_pr_url" && -n "$repo_slug_detect" ]]; then
		meta_pr_url=$(discover_pr_by_branch "$task_id" "$repo_slug_detect" "$task_branch") || meta_pr_url=""
	fi

	local meta_rate_limit_count meta_auth_error_count meta_conflict_count
	local meta_timeout_count meta_oom_count meta_backend_error_count
	meta_rate_limit_count=$(_meta_get "rate_limit_count" "0")
	meta_auth_error_count=$(_meta_get "auth_error_count" "0")
	meta_conflict_count=$(_meta_get "conflict_count" "0")
	meta_timeout_count=$(_meta_get "timeout_count" "0")
	meta_oom_count=$(_meta_get "oom_count" "0")
	meta_backend_error_count=$(_meta_get "backend_error_count" "0")

	# FULL_LOOP_COMPLETE = definitive success
	if [[ "$meta_signal" == "FULL_LOOP_COMPLETE" ]]; then
		echo "complete:${meta_pr_url:-no_pr}"
		return 0
	fi

	# t1008: Verify-mode worker signals
	# VERIFY_COMPLETE = verification confirmed prior work is done
	if [[ "$meta_signal" == "VERIFY_COMPLETE" ]]; then
		log_info "Verify worker confirmed $task_id is complete"
		echo "complete:${meta_pr_url:-verified_complete}"
		return 0
	fi

	# VERIFY_INCOMPLETE = prior work exists but needs more; worker continued implementation
	if [[ "$meta_signal" == "VERIFY_INCOMPLETE" ]]; then
		if [[ -n "$meta_pr_url" ]]; then
			log_info "Verify worker found incomplete work for $task_id, continued and created PR"
			echo "complete:${meta_pr_url}"
			return 0
		fi
		# No PR = worker found incomplete work but couldn't finish
		log_info "Verify worker found incomplete work for $task_id but no PR created"
		echo "retry:verify_incomplete_no_pr"
		return 0
	fi

	# VERIFY_NOT_STARTED = no prior work found; worker should have done full implementation
	if [[ "$meta_signal" == "VERIFY_NOT_STARTED" ]]; then
		if [[ -n "$meta_pr_url" ]]; then
			log_info "Verify worker found no prior work for $task_id, did full implementation"
			echo "complete:${meta_pr_url}"
			return 0
		fi
		# No PR = verify worker couldn't complete full implementation (expected — it's lightweight)
		log_info "Verify worker found no prior work for $task_id and couldn't complete — re-queue for full dispatch"
		echo "retry:verify_not_started_needs_full"
		return 0
	fi

	# TASK_COMPLETE with clean exit = partial success (PR phase may have failed)
	# If a PR URL is available (from DB or gh fallback), include it.
	if [[ "$meta_signal" == "TASK_COMPLETE" && "$meta_exit_code" == "0" ]]; then
		echo "complete:${meta_pr_url:-task_only}"
		return 0
	fi

	# PR URL with clean exit = task completed (PR was created successfully)
	# This takes priority over heuristic error patterns because log content
	# may discuss auth/errors as part of the task itself (e.g., creating an
	# API integration subagent that documents authentication flows)
	if [[ -n "$meta_pr_url" && "$meta_exit_code" == "0" ]]; then
		echo "complete:${meta_pr_url}"
		return 0
	fi

	# Backend infrastructure error with EXIT:0 (t095-diag-1): CLI wrappers like
	# OpenCode exit 0 even when the backend rejects the request (quota exceeded,
	# backend down). A short log with backend errors means the worker never
	# started - this is NOT content discussion, it's a real failure.
	# Must be checked BEFORE clean_exit_no_signal to avoid wasting retries.
	# (t198): Use content_lines instead of log_lines to exclude REPROMPT METADATA
	# headers that inflate the line count in retry logs (8-line header caused
	# 12-line logs to miss the < 10 threshold).
	if [[ "$meta_exit_code" == "0" && "$meta_signal" == "none" ]]; then
		local meta_content_lines
		meta_content_lines=$(_meta_get "content_lines" "0")
		# Billing/credits errors: block immediately, retrying won't help.
		# OpenCode Zen proxy returns CreditsError when credits exhausted;
		# this is a billing issue, not a transient backend error.
		if [[ "$meta_backend_error_count" -gt 0 && "$meta_content_lines" -lt 10 ]]; then
			if grep -qi 'CreditsError\|Insufficient balance' "$log_file" 2>/dev/null; then
				echo "blocked:billing_credits_exhausted"
				return 0
			fi
			echo "retry:backend_quota_error"
			return 0
		fi
	fi

	# Task obsolete detection (t198): workers that determine a task is already
	# done or obsolete exit cleanly with EXIT:0, no signal, and no PR. Without
	# this check, the supervisor retries them as clean_exit_no_signal, wasting
	# retry attempts on work that will never produce a PR.
	# Uses the final "type":"text" entry (authoritative) to detect explicit
	# "already done" / "no changes needed" language from the worker.
	if [[ "$meta_exit_code" == "0" && "$meta_signal" == "none" ]]; then
		local meta_task_obsolete
		meta_task_obsolete=$(_meta_get "task_obsolete" "false")
		if [[ "$meta_task_obsolete" == "true" ]]; then
			echo "complete:task_obsolete"
			return 0
		fi
	fi

	# Clean exit with no completion signal and no PR (checked DB + gh API above)
	# = likely incomplete. The agent finished cleanly but didn't emit a signal
	# and no PR was found. Retry (agent may have run out of context or hit a
	# soft limit). If a PR exists, it was caught at line ~3179 via DB seed (t171)
	# or gh fallback (t161).
	if [[ "$meta_exit_code" == "0" && "$meta_signal" == "none" ]]; then
		echo "retry:clean_exit_no_signal"
		return 0
	fi

	# --- Tier 2: Heuristic error pattern matching ---
	# ONLY applied when exit code is non-zero or missing.
	# When exit=0, the agent finished cleanly - any "error" strings in the log
	# are content (e.g., subagents documenting auth flows), not real failures.

	if [[ "$meta_exit_code" != "0" ]]; then
		# Backend infrastructure error (quota, API gateway) = transient retry
		# Only checked on non-zero exit: a clean exit with backend error strings in
		# the log is content discussion, not a real infrastructure failure.
		if [[ "$meta_backend_error_count" -gt 0 ]]; then
			echo "retry:backend_infrastructure_error"
			return 0
		fi

		# Auth errors are always blocking (human must fix credentials)
		if [[ "$meta_auth_error_count" -gt 0 ]]; then
			echo "blocked:auth_error"
			return 0
		fi

		# Merge conflicts require human resolution
		if [[ "$meta_conflict_count" -gt 0 ]]; then
			echo "blocked:merge_conflict"
			return 0
		fi

		# OOM is infrastructure - blocking
		if [[ "$meta_oom_count" -gt 0 ]]; then
			echo "blocked:out_of_memory"
			return 0
		fi

		# Rate limiting is transient - retry with backoff
		if [[ "$meta_rate_limit_count" -gt 0 ]]; then
			echo "retry:rate_limited"
			return 0
		fi

		# Timeout is transient - retry
		if [[ "$meta_timeout_count" -gt 0 ]]; then
			echo "retry:timeout"
			return 0
		fi
	fi

	# Non-zero exit with known code
	if [[ -n "$meta_exit_code" && "$meta_exit_code" != "0" ]]; then
		# Exit code 130 = SIGINT (Ctrl+C), 137 = SIGKILL, 143 = SIGTERM
		case "$meta_exit_code" in
		130)
			echo "retry:interrupted_sigint"
			return 0
			;;
		137)
			echo "retry:killed_sigkill"
			return 0
			;;
		143)
			echo "retry:terminated_sigterm"
			return 0
			;;
		esac
	fi

	# Check if retries exhausted before attempting AI eval
	if [[ "$tretries" -ge "$tmax_retries" ]]; then
		echo "failed:max_retries"
		return 0
	fi

	# --- Tier 2.5: Git heuristic signals (t175) ---
	# Before expensive AI eval, check for concrete evidence of work in the
	# task's worktree/branch. This resolves most ambiguous outcomes cheaply
	# and prevents false retries when the worker completed but didn't emit
	# a signal (e.g., context exhaustion after creating a PR).

	# Reuse task_repo/task_branch from PR detection above; fetch worktree
	local task_worktree
	task_worktree=$(db "$SUPERVISOR_DB" "SELECT worktree FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")

	if [[ -n "$task_repo" && -d "$task_repo" ]]; then
		# Use worktree path if available, otherwise fall back to repo
		local git_dir="${task_worktree:-$task_repo}"
		if [[ ! -d "$git_dir" ]]; then
			git_dir="$task_repo"
		fi

		# Check for commits on branch ahead of main/master
		local branch_commits=0
		if [[ -n "$task_branch" ]]; then
			local base_branch
			base_branch=$(git -C "$git_dir" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || echo "main")
			branch_commits=$(git -C "$git_dir" rev-list --count "${base_branch}..${task_branch}" 2>/dev/null || echo 0)
		fi

		# Check for uncommitted changes in worktree
		local uncommitted_changes=0
		if [[ -n "$task_worktree" && -d "$task_worktree" ]]; then
			uncommitted_changes=$(git -C "$task_worktree" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
		fi

		# Decision matrix:
		# - Commits + PR URL → complete (worker finished, signal was lost)
		# - Commits + no PR  → auto-create PR (t247.2), fallback to task_only
		# - No commits + uncommitted changes → retry:work_in_progress
		# - No commits + no changes → genuine ambiguity (fall through to AI/retry)

		if [[ "$branch_commits" -gt 0 ]]; then
			if [[ -n "$meta_pr_url" ]]; then
				echo "complete:${meta_pr_url}"
			else
				# t247.2: Auto-create PR instead of returning task_only.
				# Saves ~300s per retry by preserving work for review.
				local auto_pr_url=""
				if [[ -n "$repo_slug_detect" && -n "$task_branch" ]]; then
					auto_pr_url=$(auto_create_pr_for_task "$task_id" "$git_dir" "$task_branch" "$repo_slug_detect" 2>>"${SUPERVISOR_LOG:-/dev/null}") || auto_pr_url=""
				fi
				if [[ -n "$auto_pr_url" ]]; then
					echo "complete:${auto_pr_url}"
				else
					echo "complete:task_only"
				fi
			fi
			return 0
		fi

		if [[ "$uncommitted_changes" -gt 0 ]]; then
			echo "retry:work_in_progress"
			return 0
		fi
	fi

	# --- Tier 3: AI evaluation for ambiguous outcomes ---

	if [[ "$skip_ai_eval" == "true" ]]; then
		echo "retry:ambiguous_skipped_ai"
		return 0
	fi

	local ai_verdict
	ai_verdict=$(evaluate_with_ai "$task_id" "$tlog" 2>/dev/null || echo "")

	if [[ -n "$ai_verdict" ]]; then
		echo "$ai_verdict"
		return 0
	fi

	# AI eval failed or unavailable - default to retry
	echo "retry:ambiguous_ai_unavailable"
	return 0
}

#######################################
# Dispatch a cheap AI call to evaluate ambiguous worker outcomes
# Uses Sonnet for speed (~30s) and cost efficiency
# Returns: complete:<detail>, retry:<reason>, blocked:<reason>
#######################################
evaluate_with_ai() {
	local task_id="$1"
	local log_file="$2"

	local ai_cli
	ai_cli=$(resolve_ai_cli 2>/dev/null) || return 1

	# Extract last 200 lines of log for context (avoid sending huge logs)
	local log_tail
	log_tail=$(extract_log_tail "$log_file" 200)

	# Get task description for context
	local escaped_id
	escaped_id=$(sql_escape "$task_id")
	local task_desc
	task_desc=$(db "$SUPERVISOR_DB" "SELECT description FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")

	local eval_prompt
	eval_prompt="You are evaluating the outcome of an automated task worker. Respond with EXACTLY one line in the format: VERDICT:<type>:<detail>

Types:
- complete:<what_succeeded> (task finished successfully)
- retry:<reason> (transient failure, worth retrying)
- blocked:<reason> (needs human intervention)

Task: $task_id
Description: ${task_desc:-unknown}

Last 200 lines of worker log:
---
$log_tail
---

Analyze the log and determine the outcome. Look for:
1. Did the task complete its objective? (code changes, PR created, tests passing)
2. Is there a transient error that a retry would fix? (network, rate limit, timeout)
3. Is there a permanent blocker? (auth, permissions, merge conflict, missing dependency)

Respond with ONLY the verdict line, nothing else."

	local ai_result=""
	local eval_timeout=60
	local eval_model
	eval_model=$(resolve_model "eval" "$ai_cli")

	if [[ "$ai_cli" == "opencode" ]]; then
		ai_result=$(timeout "$eval_timeout" opencode run \
			-m "$eval_model" \
			--format text \
			--title "eval-${task_id}" \
			"$eval_prompt" 2>/dev/null || echo "")
	else
		# Strip provider prefix for claude CLI (expects bare model name)
		local claude_model="${eval_model#*/}"
		ai_result=$(timeout "$eval_timeout" claude \
			-p "$eval_prompt" \
			--model "$claude_model" \
			--output-format text 2>/dev/null || echo "")
	fi

	# Parse the VERDICT line from AI response
	local verdict_line
	verdict_line=$(echo "$ai_result" | grep -o 'VERDICT:[a-z]*:[a-z_]*' | head -1 || true)

	if [[ -n "$verdict_line" ]]; then
		# Strip VERDICT: prefix and return
		local verdict="${verdict_line#VERDICT:}"
		log_info "AI eval for $task_id: $verdict"

		# Store AI evaluation in state log for audit trail
		db "$SUPERVISOR_DB" "
            INSERT INTO state_log (task_id, from_state, to_state, reason)
            VALUES ('$(sql_escape "$task_id")', 'evaluating', 'evaluating',
                    'AI eval verdict: $verdict');
        " 2>/dev/null || true

		echo "$verdict"
		return 0
	fi

	# AI didn't return a parseable verdict
	log_warn "AI eval for $task_id returned unparseable result"
	return 1
}

#######################################
# Manually evaluate a task's worker outcome
# Useful for debugging or forcing evaluation of a stuck task
#######################################
cmd_evaluate() {
	local task_id="" skip_ai="false"

	if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
		task_id="$1"
		shift
	fi

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--no-ai)
			skip_ai=true
			shift
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$task_id" ]]; then
		log_error "Usage: supervisor-helper.sh evaluate <task_id> [--no-ai]"
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

	# Run evaluation
	echo -e "${BOLD}=== Evaluation Result ===${NC}"
	local outcome
	outcome=$(evaluate_worker "$task_id" "$skip_ai")
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
