#!/usr/bin/env bash
# issue-sync.sh - GitHub issue and label sync functions
#
# Functions for issue creation, status labels, task claiming,
# staleness checks, and GitHub synchronization

#######################################
# Ensure status labels exist in the repo (t164)
# Creates status:available, status:claimed, status:in-review, status:done
# if they don't already exist. Idempotent — safe to call repeatedly.
# $1: repo_slug (e.g. "owner/repo")
#######################################
ensure_status_labels() {
	local repo_slug="${1:-}"
	if [[ -z "$repo_slug" ]]; then
		return 0
	fi

	# --force updates existing labels without error, creates if missing
	# t1009: Full set of status labels for state-transition tracking
	gh label create "status:available" --repo "$repo_slug" --color "0E8A16" --description "Task is available for claiming" --force 2>/dev/null || true
	gh label create "status:queued" --repo "$repo_slug" --color "C5DEF5" --description "Task is queued for dispatch" --force 2>/dev/null || true
	gh label create "status:claimed" --repo "$repo_slug" --color "D93F0B" --description "Task is claimed by a worker" --force 2>/dev/null || true
	gh label create "status:in-review" --repo "$repo_slug" --color "FBCA04" --description "Task PR is in review" --force 2>/dev/null || true
	gh label create "status:blocked" --repo "$repo_slug" --color "B60205" --description "Task is blocked" --force 2>/dev/null || true
	gh label create "status:verify-failed" --repo "$repo_slug" --color "E4E669" --description "Task verification failed" --force 2>/dev/null || true
	gh label create "status:done" --repo "$repo_slug" --color "6F42C1" --description "Task is complete" --force 2>/dev/null || true
	return 0
}

#######################################
# Extract model tier name from a full model string (t1010)
# Maps provider/model strings to tier names (haiku, flash, sonnet, pro, opus).
# $1: model string (e.g. "anthropic/claude-opus-4-6")
# Outputs tier name on stdout, empty if unrecognised.
#######################################
model_to_tier() {
	local model_str="${1:-}"
	if [[ -z "$model_str" ]]; then
		return 0
	fi
	# Order matters: specific patterns before generic ones (ShellCheck SC2221/SC2222)
	case "$model_str" in
	*gpt-4.1-mini*) echo "flash" ;;
	*gpt-4.1*) echo "sonnet" ;;
	*gemini-2.5-flash*) echo "flash" ;;
	*gemini-2.5-pro*) echo "pro" ;;
	*haiku*) echo "haiku" ;;
	*flash*) echo "flash" ;;
	*sonnet*) echo "sonnet" ;;
	*opus*) echo "opus" ;;
	*pro*) echo "pro" ;;
	*o3*) echo "opus" ;;
	*) echo "" ;;
	esac
	return 0
}

#######################################
# Add an action:model label to a GitHub issue (t1010)
# Labels track which model was used for each lifecycle action.
# Format: "action:tier" (e.g. "implemented:opus", "failed:sonnet")
# Labels are append-only (history, not state) — never removed.
# Created on-demand via gh label create --force (idempotent).
#
# Valid actions: dispatched, implemented, reviewed, verified,
#   documented, failed, retried, escalated, planned, researched
#
# $1: task_id
# $2: action (e.g. "implemented", "failed", "retried")
# $3: model_tier (e.g. "opus", "sonnet") — or full model string (auto-extracted)
# $4: project_root (optional)
#
# Fails silently if: gh not available, no auth, no issue ref, or API error.
# This is best-effort — label failures must never block task processing.
#######################################
add_model_label() {
	local task_id="${1:-}"
	local action="${2:-}"
	local model_input="${3:-}"
	local project_root="${4:-}"

	# Validate required params
	if [[ -z "$task_id" || -z "$action" || -z "$model_input" ]]; then
		return 0
	fi

	# Skip if gh CLI not available or not authenticated
	command -v gh &>/dev/null || return 0
	check_gh_auth || return 0

	# Resolve model tier from full model string if needed
	local tier="$model_input"
	case "$model_input" in
	haiku | flash | sonnet | pro | opus) ;; # Already a tier name
	*)
		tier=$(model_to_tier "$model_input")
		if [[ -z "$tier" ]]; then
			return 0
		fi
		;;
	esac

	# Find the GitHub issue number
	local issue_number
	issue_number=$(find_task_issue_number "$task_id" "$project_root")
	if [[ -z "$issue_number" ]]; then
		return 0
	fi

	# Detect repo slug
	if [[ -z "$project_root" ]]; then
		project_root=$(find_project_root 2>/dev/null || echo ".")
	fi
	local repo_slug
	repo_slug=$(detect_repo_slug "$project_root" 2>/dev/null || echo "")
	if [[ -z "$repo_slug" ]]; then
		return 0
	fi

	local label_name="${action}:${tier}"

	# Color scheme by action category:
	#   dispatch/implement = blue shades (productive work)
	#   review/verify/document = green shades (quality work)
	#   fail/retry/escalate = red/orange shades (problems)
	#   plan/research = purple shades (preparation)
	local label_color label_desc
	case "$action" in
	dispatched)
		label_color="1D76DB"
		label_desc="Task dispatched to $tier model"
		;;
	implemented)
		label_color="0075CA"
		label_desc="Task implemented by $tier model"
		;;
	reviewed)
		label_color="0E8A16"
		label_desc="Task reviewed by $tier model"
		;;
	verified)
		label_color="2EA44F"
		label_desc="Task verified by $tier model"
		;;
	documented)
		label_color="A2EEEF"
		label_desc="Task documented by $tier model"
		;;
	failed)
		label_color="D93F0B"
		label_desc="Task failed with $tier model"
		;;
	retried)
		label_color="E4E669"
		label_desc="Task retried with $tier model"
		;;
	escalated)
		label_color="FBCA04"
		label_desc="Task escalated from $tier model"
		;;
	planned)
		label_color="D4C5F9"
		label_desc="Task planned with $tier model"
		;;
	researched)
		label_color="C5DEF5"
		label_desc="Task researched with $tier model"
		;;
	*)
		label_color="BFDADC"
		label_desc="Model $tier used for $action"
		;;
	esac

	# Create label on-demand (idempotent — --force updates if exists)
	gh label create "$label_name" --repo "$repo_slug" \
		--color "$label_color" --description "$label_desc" \
		--force 2>/dev/null || true

	# Add label to issue (append-only — never remove model labels)
	gh issue edit "$issue_number" --repo "$repo_slug" \
		--add-label "$label_name" 2>/dev/null || true

	log_info "Added label '$label_name' to issue #$issue_number for $task_id (t1010)"
	return 0
}

#######################################
# Query model usage labels for analysis (t1010)
# Lists all action:model labels on issues in the repo.
# Supports filtering by action, model tier, or both.
#
# Usage: cmd_labels [--action ACTION] [--model TIER] [--repo SLUG] [--json]
#######################################
cmd_labels() {
	local action_filter="" model_filter="" repo_slug="" json_output="false"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--action)
			action_filter="$2"
			shift 2
			;;
		--model)
			model_filter="$2"
			shift 2
			;;
		--repo)
			repo_slug="$2"
			shift 2
			;;
		--json)
			json_output="true"
			shift
			;;
		*)
			shift
			;;
		esac
	done

	# Detect repo if not provided
	if [[ -z "$repo_slug" ]]; then
		local project_root
		project_root=$(find_project_root 2>/dev/null || echo ".")
		repo_slug=$(detect_repo_slug "$project_root" 2>/dev/null || echo "")
	fi

	if [[ -z "$repo_slug" ]]; then
		log_error "Cannot detect repo slug. Use --repo owner/repo"
		return 1
	fi

	# Skip if gh CLI not available
	if ! command -v gh &>/dev/null; then
		log_error "gh CLI not available"
		return 1
	fi

	# Build label search pattern
	local label_pattern=""
	if [[ -n "$action_filter" && -n "$model_filter" ]]; then
		label_pattern="${action_filter}:${model_filter}"
	elif [[ -n "$action_filter" ]]; then
		label_pattern="${action_filter}:"
	elif [[ -n "$model_filter" ]]; then
		label_pattern=":${model_filter}"
	fi

	# Valid actions for model tracking
	local valid_actions="dispatched implemented reviewed verified documented failed retried escalated planned researched"

	if [[ "$json_output" == "true" ]]; then
		# JSON output: list all model labels with issue counts
		local first_entry="true"
		printf '['
		for act in $valid_actions; do
			for tier in haiku flash sonnet pro opus; do
				local lbl="${act}:${tier}"
				# Skip if doesn't match filter
				if [[ -n "$label_pattern" && "$lbl" != *"$label_pattern"* ]]; then
					continue
				fi
				local count
				count=$(gh issue list --repo "$repo_slug" --label "$lbl" --state all --json number --jq 'length' 2>/dev/null || echo "0")
				if [[ "$count" -gt 0 ]]; then
					if [[ "$first_entry" == "true" ]]; then
						first_entry="false"
					else
						printf ','
					fi
					printf '{"label":"%s","action":"%s","model":"%s","count":%d}' "$lbl" "$act" "$tier" "$count"
				fi
			done
		done
		printf ']\n'
	else
		# Human-readable output
		echo -e "${BOLD}Model Usage Labels${NC} ($repo_slug)"
		echo "─────────────────────────────────────"

		local found=0
		for act in $valid_actions; do
			local act_found=0
			for tier in haiku flash sonnet pro opus; do
				local lbl="${act}:${tier}"
				if [[ -n "$label_pattern" && "$lbl" != *"$label_pattern"* ]]; then
					continue
				fi
				local count
				count=$(gh issue list --repo "$repo_slug" --label "$lbl" --state all --json number --jq 'length' 2>/dev/null || echo "0")
				if [[ "$count" -gt 0 ]]; then
					if [[ "$act_found" -eq 0 ]]; then
						echo ""
						echo -e "${BOLD}${act}${NC}:"
						act_found=1
					fi
					printf "  %-10s %d issues\n" "$tier" "$count"
					found=1
				fi
			done
		done

		if [[ "$found" -eq 0 ]]; then
			echo ""
			echo "No model usage labels found."
			echo "Labels are added automatically during supervisor dispatch and evaluation."
		fi
		echo ""
	fi
	return 0
}

#######################################
# Map supervisor state to GitHub issue status label (t1009)
# Returns the label name for a given state, empty if no label applies
# (terminal states that close the issue return empty).
# $1: supervisor state
#######################################
state_to_status_label() {
	local state="$1"
	case "$state" in
	queued) echo "status:queued" ;;
	dispatched | running | evaluating | retrying) echo "status:claimed" ;;
	complete | pr_review | review_triage | merging) echo "status:in-review" ;;
	merged | deploying) echo "status:in-review" ;;
	blocked) echo "status:blocked" ;;
	verify_failed) echo "status:verify-failed" ;;
	# Terminal states: verified/deployed close the issue, cancelled closes as not-planned
	# These return empty — the caller handles close logic separately
	verified | deployed | cancelled | failed) echo "" ;;
	*) echo "" ;;
	esac
	return 0
}

#######################################
# Sync GitHub issue status label on state transition (t1009)
# Called from cmd_transition() after each state change.
# Removes all status:* labels, then adds the one matching the new state.
# For terminal states (verified, deployed, cancelled), closes the issue.
# Best-effort: silently skips if gh CLI unavailable or no issue linked.
# $1: task_id
# $2: new_state
# $3: old_state (for logging)
#######################################
sync_issue_status_label() {
	local task_id="$1"
	local new_state="$2"
	local old_state="${3:-}"

	# Skip if gh CLI not available or not authenticated
	command -v gh &>/dev/null || return 0
	check_gh_auth || return 0

	# Find the repo path from the task's DB record
	local escaped_id
	escaped_id=$(sql_escape "$task_id")
	local repo_path
	repo_path=$(db "$SUPERVISOR_DB" "SELECT repo FROM tasks WHERE id = '$escaped_id';" 2>/dev/null || echo "")
	if [[ -z "$repo_path" ]]; then
		repo_path=$(find_project_root 2>/dev/null || echo ".")
	fi

	local issue_number
	issue_number=$(find_task_issue_number "$task_id" "$repo_path")
	if [[ -z "$issue_number" ]]; then
		log_verbose "sync_issue_status_label: no GH issue for $task_id, skipping"
		return 0
	fi

	local repo_slug
	repo_slug=$(detect_repo_slug "$repo_path" 2>/dev/null || echo "")
	if [[ -z "$repo_slug" ]]; then
		return 0
	fi

	# Ensure all status labels exist on the repo
	ensure_status_labels "$repo_slug"

	# Determine the new label
	local new_label
	new_label=$(state_to_status_label "$new_state")

	# Build remove args for all status labels except the new one
	local -a remove_args=()
	local label
	while IFS=',' read -ra labels; do
		for label in "${labels[@]}"; do
			if [[ "$label" != "$new_label" ]]; then
				remove_args+=("--remove-label" "$label")
			fi
		done
	done <<<"$ALL_STATUS_LABELS"

	# Handle terminal states that close the issue
	case "$new_state" in
	verified | deployed)
		# Close the issue with a completion comment
		gh issue close "$issue_number" --repo "$repo_slug" \
			--comment "Task $task_id reached state: $new_state (from $old_state)" 2>/dev/null || true
		# Add status:done and remove all other status labels
		gh issue edit "$issue_number" --repo "$repo_slug" \
			--add-label "status:done" "${remove_args[@]}" 2>/dev/null || true
		log_verbose "sync_issue_status_label: closed #$issue_number ($task_id -> $new_state)"
		return 0
		;;
	cancelled)
		# Close as not-planned
		gh issue close "$issue_number" --repo "$repo_slug" --reason "not planned" \
			--comment "Task $task_id cancelled (was: $old_state)" 2>/dev/null || true
		# Remove all status labels
		gh issue edit "$issue_number" --repo "$repo_slug" \
			"${remove_args[@]}" 2>/dev/null || true
		log_verbose "sync_issue_status_label: closed #$issue_number as not-planned ($task_id)"
		return 0
		;;
	failed)
		# Close with failure comment but don't add status:done
		gh issue close "$issue_number" --repo "$repo_slug" \
			--comment "Task $task_id failed (was: $old_state)" 2>/dev/null || true
		gh issue edit "$issue_number" --repo "$repo_slug" \
			"${remove_args[@]}" 2>/dev/null || true
		log_verbose "sync_issue_status_label: closed #$issue_number as failed ($task_id)"
		return 0
		;;
	esac

	# Non-terminal state: apply the new label, remove all others
	if [[ -n "$new_label" ]]; then
		gh issue edit "$issue_number" --repo "$repo_slug" \
			--add-label "$new_label" "${remove_args[@]}" 2>/dev/null || true
		log_verbose "sync_issue_status_label: #$issue_number -> $new_label ($task_id: $old_state -> $new_state)"
	fi

	# Reopen the issue if it was closed and we're transitioning to a non-terminal state
	# (e.g., failed -> queued for retry, blocked -> queued)
	if [[ -n "$new_label" ]]; then
		local issue_state
		issue_state=$(gh issue view "$issue_number" --repo "$repo_slug" --json state --jq '.state' 2>/dev/null || echo "")
		if [[ "$issue_state" == "CLOSED" ]]; then
			gh issue reopen "$issue_number" --repo "$repo_slug" \
				--comment "Task $task_id re-entered pipeline: $old_state -> $new_state" 2>/dev/null || true
			log_verbose "sync_issue_status_label: reopened #$issue_number ($task_id: $old_state -> $new_state)"
		fi
	fi

	return 0
}

#######################################
# Update pinned queue health issue with live supervisor status (t1013)
#
# Creates or updates a single comment on a pinned GitHub issue with:
#   - Running/queued/blocked counts
#   - Active worker table (task, model, duration)
#   - Recent completions (last 5)
#   - System resources snapshot
#   - Alerts section (stale batches, auth failures, stuck workers)
#   - "Last pulse" timestamp
#
# The comment is edited in-place (not appended) using the GitHub API.
# The comment ID is cached to avoid repeated lookups.
#
# Graceful degradation: never breaks the pulse if gh fails.
#
# $1: batch_id (optional)
# $2: repo_slug (required — caller provides)
# $3: repo_path (required — local path for DB filtering)
# Returns: 0 always (best-effort)
#######################################
update_queue_health_issue() {
	local batch_id="${1:-}"
	local repo_slug="${2:-}"
	local repo_path="${3:-}"

	# Require gh CLI, authentication, and repo info
	command -v gh &>/dev/null || return 0
	check_gh_auth 2>/dev/null || return 0
	[[ -z "$repo_slug" ]] && return 0
	[[ -z "$repo_path" ]] && return 0

	# SQL filter for this repo
	local repo_filter="repo = '${repo_path}'"

	# Per-runner health issue: each supervisor instance owns its own issue
	local runner_user
	runner_user=$(gh api user --jq '.login' 2>/dev/null || whoami)
	local runner_prefix="[Supervisor:${runner_user}]"

	local health_issue_file="${SUPERVISOR_DIR}/queue-health-issue-${runner_user}"
	local health_comment_file="${SUPERVISOR_DIR}/queue-health-comment-id-${runner_user}"
	local health_issue_number=""

	# Try cached issue number first
	if [[ -f "$health_issue_file" ]]; then
		health_issue_number=$(cat "$health_issue_file" 2>/dev/null || echo "")
	fi

	# Validate cached issue still exists and is open
	if [[ -n "$health_issue_number" ]]; then
		local issue_state
		issue_state=$(gh issue view "$health_issue_number" --repo "$repo_slug" --json state --jq '.state' 2>/dev/null || echo "")
		if [[ "$issue_state" != "OPEN" ]]; then
			health_issue_number=""
			rm -f "$health_issue_file" "$health_comment_file" 2>/dev/null || true
		fi
	fi

	# Search for this runner's existing health issue
	if [[ -z "$health_issue_number" ]]; then
		health_issue_number=$(gh issue list --repo "$repo_slug" \
			--search "in:title ${runner_prefix}" \
			--state open --json number,title \
			--jq "[.[] | select(.title | startswith(\"${runner_prefix}\"))][0].number" 2>/dev/null || echo "")
	fi

	# Create the issue if it doesn't exist
	if [[ -z "$health_issue_number" ]]; then
		# Ensure username label exists
		gh label create "$runner_user" --repo "$repo_slug" --color "0E8A16" --description "Supervisor runner: ${runner_user}" 2>/dev/null || true
		health_issue_number=$(gh issue create --repo "$repo_slug" \
			--title "${runner_prefix} starting..." \
			--body "Live supervisor queue status for **${runner_user}**. Updated when stats change. Pin this issue for at-a-glance monitoring." \
			--label "supervisor" --label "$runner_user" 2>/dev/null | grep -oE '[0-9]+$' || echo "")
		if [[ -z "$health_issue_number" ]]; then
			log_verbose "  Phase 8c: Could not create health issue"
			return 0
		fi
		# Pin the issue (best-effort — requires admin permissions)
		gh api graphql -f query="
			mutation {
				pinIssue(input: {issueId: \"$(gh issue view "$health_issue_number" --repo "$repo_slug" --json id --jq '.id' 2>/dev/null || echo "")\"}) {
					issue { number }
				}
			}" >/dev/null 2>&1 || true
		log_info "  Phase 8c: Created and pinned health issue #$health_issue_number for ${runner_user}"
	fi

	# Cache the issue number
	echo "$health_issue_number" >"$health_issue_file"

	# --- Generate status markdown ---
	local now_iso
	now_iso=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

	# Counts
	local cnt_running cnt_queued cnt_blocked cnt_failed cnt_complete cnt_total
	local cnt_pr_review cnt_retrying cnt_dispatched
	cnt_running=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM tasks WHERE ${repo_filter} AND status = 'running';" 2>/dev/null || echo "0")
	cnt_dispatched=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM tasks WHERE ${repo_filter} AND status = 'dispatched';" 2>/dev/null || echo "0")
	cnt_queued=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM tasks WHERE ${repo_filter} AND status = 'queued';" 2>/dev/null || echo "0")
	cnt_blocked=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM tasks WHERE ${repo_filter} AND status = 'blocked';" 2>/dev/null || echo "0")
	cnt_failed=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM tasks WHERE ${repo_filter} AND status = 'failed';" 2>/dev/null || echo "0")
	cnt_retrying=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM tasks WHERE ${repo_filter} AND status = 'retrying';" 2>/dev/null || echo "0")
	cnt_pr_review=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM tasks WHERE ${repo_filter} AND status IN ('pr_review','review_triage','merging','merged','deploying');" 2>/dev/null || echo "0")
	cnt_complete=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM tasks WHERE ${repo_filter} AND status IN ('complete','deployed','verified');" 2>/dev/null || echo "0")
	cnt_total=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM tasks WHERE ${repo_filter};" 2>/dev/null || echo "0")
	# Actionable total excludes cancelled/skipped tasks for accurate progress
	local cnt_cancelled cnt_skipped cnt_actionable
	cnt_cancelled=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM tasks WHERE ${repo_filter} AND status = 'cancelled';" 2>/dev/null || echo "0")
	cnt_skipped=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM tasks WHERE ${repo_filter} AND status = 'skipped';" 2>/dev/null || echo "0")
	cnt_actionable=$((cnt_total - cnt_cancelled - cnt_skipped))
	local cnt_verify_failed
	cnt_verify_failed=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM tasks WHERE ${repo_filter} AND status = 'verify_failed';" 2>/dev/null || echo "0")

	# Active batch info
	local active_batch_name=""
	if [[ -n "$batch_id" ]]; then
		local escaped_batch
		escaped_batch=$(sql_escape "$batch_id")
		active_batch_name=$(db "$SUPERVISOR_DB" "SELECT name FROM batches WHERE id = '$escaped_batch';" 2>/dev/null || echo "$batch_id")
	else
		active_batch_name=$(db "$SUPERVISOR_DB" "SELECT name FROM batches WHERE status = 'active' ORDER BY created_at DESC LIMIT 1;" 2>/dev/null || echo "none")
	fi

	# Active workers table
	local workers_md=""
	local active_workers
	active_workers=$(db -separator '|' "$SUPERVISOR_DB" "
		SELECT id, status, description, model, started_at, retries, pr_url
		FROM tasks
		WHERE ${repo_filter} AND status IN ('running', 'dispatched', 'evaluating')
		ORDER BY started_at ASC;" 2>/dev/null || echo "")

	if [[ -n "$active_workers" ]]; then
		workers_md="| Task | Status | Description | Model | Duration | Retries | PR |
| --- | --- | --- | --- | --- | --- | --- |
"
		while IFS='|' read -r w_id w_status w_desc w_model w_started w_retries w_pr; do
			[[ -z "$w_id" ]] && continue
			# Calculate duration
			local w_duration="--"
			if [[ -n "$w_started" ]]; then
				local w_start_epoch w_now_epoch w_elapsed_s
				w_start_epoch=$(date -jf "%Y-%m-%dT%H:%M:%S" "${w_started%%Z*}" +%s 2>/dev/null || date -d "$w_started" +%s 2>/dev/null || echo "0")
				w_now_epoch=$(date +%s)
				if [[ "$w_start_epoch" -gt 0 ]]; then
					w_elapsed_s=$((w_now_epoch - w_start_epoch))
					local w_min=$((w_elapsed_s / 60))
					local w_sec=$((w_elapsed_s % 60))
					w_duration="${w_min}m${w_sec}s"
				fi
			fi
			# Truncate description
			local w_desc_short="${w_desc:0:50}"
			[[ ${#w_desc} -gt 50 ]] && w_desc_short="${w_desc_short}..."
			# Model short name
			local w_model_short="${w_model##*/}"
			[[ -z "$w_model_short" ]] && w_model_short="--"
			# PR link
			local w_pr_display="--"
			if [[ -n "$w_pr" ]]; then
				local w_pr_num
				w_pr_num=$(echo "$w_pr" | grep -oE '[0-9]+$' || echo "")
				if [[ -n "$w_pr_num" ]]; then
					w_pr_display="#${w_pr_num}"
				fi
			fi
			# Status emoji
			local w_status_icon
			case "$w_status" in
			running) w_status_icon="running" ;;
			dispatched) w_status_icon="dispatched" ;;
			evaluating) w_status_icon="evaluating" ;;
			*) w_status_icon="$w_status" ;;
			esac
			workers_md="${workers_md}| \`${w_id}\` | ${w_status_icon} | ${w_desc_short} | ${w_model_short} | ${w_duration} | ${w_retries} | ${w_pr_display} |
"
		done <<<"$active_workers"
	else
		workers_md="_No active workers_"
	fi

	# Recent completions (last 5)
	local completions_md=""
	local recent_completions
	recent_completions=$(db -separator '|' "$SUPERVISOR_DB" "
		SELECT id, status, description, completed_at, pr_url
		FROM tasks
		WHERE ${repo_filter} AND status IN ('complete', 'deployed', 'verified', 'merged')
		ORDER BY completed_at DESC
		LIMIT 5;" 2>/dev/null || echo "")

	if [[ -n "$recent_completions" ]]; then
		completions_md="| Task | Status | Description | Completed | PR |
| --- | --- | --- | --- | --- |
"
		while IFS='|' read -r c_id c_status c_desc c_completed c_pr; do
			[[ -z "$c_id" ]] && continue
			local c_desc_short="${c_desc:0:50}"
			[[ ${#c_desc} -gt 50 ]] && c_desc_short="${c_desc_short}..."
			local c_time="--"
			if [[ -n "$c_completed" ]]; then
				c_time="${c_completed:0:16}"
			fi
			local c_pr_display="--"
			if [[ -n "$c_pr" ]]; then
				local c_pr_num
				c_pr_num=$(echo "$c_pr" | grep -oE '[0-9]+$' || echo "")
				[[ -n "$c_pr_num" ]] && c_pr_display="#${c_pr_num}"
			fi
			completions_md="${completions_md}| \`${c_id}\` | ${c_status} | ${c_desc_short} | ${c_time} | ${c_pr_display} |
"
		done <<<"$recent_completions"
	else
		completions_md="_No recent completions_"
	fi

	# System resources — use lightweight metrics to avoid blocking the pulse
	# (check_system_load uses top -l 2 which takes ~2s and can hang)
	local sys_md=""
	local h_cpu_cores h_load_1m h_load_5m h_proc_count h_memory
	h_cpu_cores=$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo "?")
	if [[ "$(uname)" == "Darwin" ]]; then
		local load_str
		load_str=$(sysctl -n vm.loadavg 2>/dev/null || echo "{ 0 0 0 }")
		h_load_1m=$(echo "$load_str" | awk '{print $2}')
		h_load_5m=$(echo "$load_str" | awk '{print $3}')
	elif [[ -f /proc/loadavg ]]; then
		read -r h_load_1m h_load_5m _ </proc/loadavg
	fi
	h_proc_count=$(ps aux 2>/dev/null | wc -l | tr -d ' ')
	# Memory pressure — use vm_stat (instant) instead of memory_pressure (slow/hangs)
	h_memory="unknown"
	if [[ "$(uname)" == "Darwin" ]]; then
		local vm_free vm_inactive vm_speculative page_size_bytes
		page_size_bytes=$(sysctl -n hw.pagesize 2>/dev/null || echo "4096")
		vm_free=$(vm_stat 2>/dev/null | awk '/Pages free/ {gsub(/\./,"",$3); print $3}')
		vm_inactive=$(vm_stat 2>/dev/null | awk '/Pages inactive/ {gsub(/\./,"",$3); print $3}')
		vm_speculative=$(vm_stat 2>/dev/null | awk '/Pages speculative/ {gsub(/\./,"",$3); print $3}')
		if [[ -n "$vm_free" ]]; then
			local avail_pages=$((${vm_free:-0} + ${vm_inactive:-0} + ${vm_speculative:-0}))
			local avail_mb=$((avail_pages * page_size_bytes / 1048576))
			if [[ "$avail_mb" -lt 1024 ]]; then
				h_memory="high (${avail_mb}MB free)"
			elif [[ "$avail_mb" -lt 4096 ]]; then
				h_memory="medium (${avail_mb}MB free)"
			else
				h_memory="low (${avail_mb}MB free)"
			fi
		fi
	elif [[ -f /proc/meminfo ]]; then
		local mem_avail
		mem_avail=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo "")
		if [[ -n "$mem_avail" ]]; then
			if [[ "$mem_avail" -lt 1024 ]]; then
				h_memory="high (${mem_avail}MB free)"
			elif [[ "$mem_avail" -lt 4096 ]]; then
				h_memory="medium (${mem_avail}MB free)"
			else
				h_memory="low (${mem_avail}MB free)"
			fi
		fi
	fi
	# Compute load ratio from load average
	local h_load_ratio="?"
	if [[ -n "${h_load_1m:-}" && -n "${h_cpu_cores:-}" && "${h_cpu_cores}" != "?" && "${h_cpu_cores:-0}" -gt 0 ]]; then
		h_load_ratio=$(awk "BEGIN {printf \"%d\", (${h_load_1m} / ${h_cpu_cores}) * 100}" 2>/dev/null || echo "?")
	fi
	sys_md="| Metric | Value |
| --- | --- |
| CPU | ${h_load_ratio}% used (${h_cpu_cores:-?} cores, load: ${h_load_1m:-?}/${h_load_5m:-?}) |
| Memory | ${h_memory:-unknown} |
| Processes | ${h_proc_count:-?} |"

	# Alerts section
	local alerts_md=""
	local alert_count=0

	# Alert: failed tasks
	if [[ "${cnt_failed:-0}" -gt 0 ]]; then
		local failed_list
		failed_list=$(db -separator '|' "$SUPERVISOR_DB" "SELECT id, error FROM tasks WHERE ${repo_filter} AND status = 'failed' LIMIT 5;" 2>/dev/null || echo "")
		alerts_md="${alerts_md}- **${cnt_failed} failed task(s)**:"
		while IFS='|' read -r f_id f_err; do
			[[ -z "$f_id" ]] && continue
			local f_err_short="${f_err:0:80}"
			[[ ${#f_err} -gt 80 ]] && f_err_short="${f_err_short}..."
			alerts_md="${alerts_md}
  - \`${f_id}\`: ${f_err_short:-unknown error}"
		done <<<"$failed_list"
		alerts_md="${alerts_md}
"
		alert_count=$((alert_count + 1))
	fi

	# Alert: blocked tasks
	if [[ "${cnt_blocked:-0}" -gt 0 ]]; then
		alerts_md="${alerts_md}- **${cnt_blocked} blocked task(s)**
"
		alert_count=$((alert_count + 1))
	fi

	# Alert: retrying tasks
	if [[ "${cnt_retrying:-0}" -gt 0 ]]; then
		alerts_md="${alerts_md}- **${cnt_retrying} task(s) retrying**
"
		alert_count=$((alert_count + 1))
	fi

	# Alert: stale batch (no dispatches in 10+ pulses)
	local last_dispatch_ts
	last_dispatch_ts=$(db "$SUPERVISOR_DB" "SELECT MAX(started_at) FROM tasks WHERE ${repo_filter} AND status IN ('running','dispatched','evaluating');" 2>/dev/null || echo "")
	if [[ -n "$last_dispatch_ts" && "$last_dispatch_ts" != "" ]]; then
		local ld_epoch ld_now ld_age_min
		ld_epoch=$(date -jf "%Y-%m-%dT%H:%M:%S" "${last_dispatch_ts%%Z*}" +%s 2>/dev/null || date -d "$last_dispatch_ts" +%s 2>/dev/null || echo "0")
		ld_now=$(date +%s)
		if [[ "$ld_epoch" -gt 0 ]]; then
			ld_age_min=$(((ld_now - ld_epoch) / 60))
			if [[ "$ld_age_min" -gt 20 && "${cnt_queued:-0}" -gt 0 ]]; then
				alerts_md="${alerts_md}- **Stale queue**: ${cnt_queued} task(s) queued but no dispatch in ${ld_age_min}min
"
				alert_count=$((alert_count + 1))
			fi
		fi
	elif [[ "${cnt_queued:-0}" -gt 0 ]]; then
		alerts_md="${alerts_md}- **Stale queue**: ${cnt_queued} task(s) queued but no active workers
"
		alert_count=$((alert_count + 1))
	fi

	# Alert: system overload (load ratio > 200% of cores)
	local h_overloaded="false"
	if [[ "${h_load_ratio:-0}" != "?" && "${h_load_ratio:-0}" -gt 200 ]] 2>/dev/null; then
		h_overloaded="true"
	fi
	if [[ "$h_overloaded" == "true" ]]; then
		alerts_md="${alerts_md}- **System overloaded** — adaptive throttling active
"
		alert_count=$((alert_count + 1))
	fi

	if [[ "$alert_count" -eq 0 ]]; then
		alerts_md="_No alerts — all clear_"
	fi

	# Progress bar
	local progress_pct=0
	if [[ "${cnt_actionable:-0}" -gt 0 ]]; then
		progress_pct=$(((cnt_complete * 100) / cnt_actionable))
	fi
	local progress_filled=$((progress_pct / 5))
	local progress_empty=$((20 - progress_filled))
	local progress_bar=""
	local pi
	for ((pi = 0; pi < progress_filled; pi++)); do
		progress_bar="${progress_bar}#"
	done
	for ((pi = 0; pi < progress_empty; pi++)); do
		progress_bar="${progress_bar}-"
	done

	# Queued task list (next 5 in queue)
	local queued_md=""
	local queued_tasks
	queued_tasks=$(db -separator '|' "$SUPERVISOR_DB" "
		SELECT id, description, model
		FROM tasks
		WHERE ${repo_filter} AND status = 'queued'
		ORDER BY created_at ASC
		LIMIT 5;" 2>/dev/null || echo "")

	if [[ -n "$queued_tasks" ]]; then
		queued_md="| Task | Description | Model |
| --- | --- | --- |
"
		while IFS='|' read -r q_id q_desc q_model; do
			[[ -z "$q_id" ]] && continue
			local q_desc_short="${q_desc:0:60}"
			[[ ${#q_desc} -gt 60 ]] && q_desc_short="${q_desc_short}..."
			local q_model_short="${q_model##*/}"
			[[ -z "$q_model_short" ]] && q_model_short="--"
			queued_md="${queued_md}| \`${q_id}\` | ${q_desc_short} | ${q_model_short} |
"
		done <<<"$queued_tasks"
	fi

	# Assemble the full markdown body
	local body
	body="## Queue Health Dashboard

**Last pulse**: \`${now_iso}\`
**Active batch**: \`${active_batch_name}\`

### Summary

\`\`\`
[${progress_bar}] ${progress_pct}% (${cnt_complete}/${cnt_actionable} actionable)
\`\`\`

| Status | Count |
| --- | --- |
| Running | ${cnt_running} |
| Dispatched | ${cnt_dispatched} |
| Queued | ${cnt_queued} |
| In Review | ${cnt_pr_review} |
| Retrying | ${cnt_retrying} |
| Blocked | ${cnt_blocked} |
| Failed | ${cnt_failed} |
| Verify Failed | ${cnt_verify_failed} |
| Complete | ${cnt_complete} |
| Cancelled | ${cnt_cancelled} |
| **Actionable** | **${cnt_actionable}** |

### Active Workers

${workers_md}

### Up Next (Queued)

${queued_md:-_Queue empty_}

### Recent Completions

${completions_md}

### System Resources

${sys_md}

### Alerts

${alerts_md}

---
_Auto-updated by supervisor pulse (t1013). Do not edit manually._"

	# Update the issue description (body) directly — no comments needed
	gh issue edit "$health_issue_number" --repo "$repo_slug" --body "$body" >/dev/null 2>&1 || {
		log_verbose "  Phase 8c: Failed to update issue body"
		return 0
	}

	# Build title with operational stats from this runner's perspective
	local cnt_working
	cnt_working=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM tasks WHERE ${repo_filter} AND status IN ('running','dispatched','evaluating');" 2>/dev/null || echo "0")
	local cnt_in_review
	cnt_in_review=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM tasks WHERE ${repo_filter} AND status IN ('pr_review','review_triage','merging','merged','deploying','retrying');" 2>/dev/null || echo "0")
	local cnt_failed_total=$((${cnt_blocked:-0} + ${cnt_verify_failed:-0} + ${cnt_failed:-0}))

	local title_parts="${cnt_queued:-0} queued, ${cnt_working} working"
	if [[ "${cnt_in_review}" -gt 0 ]]; then
		title_parts="${title_parts}, ${cnt_in_review} in review"
	fi
	if [[ "${cnt_failed_total}" -gt 0 ]]; then
		title_parts="${title_parts}, ${cnt_failed_total} need attention"
	fi

	local title_time
	title_time=$(date -u +"%H:%M")
	local health_title="${runner_prefix} ${title_parts} at ${title_time} UTC"

	# Only update title if stats changed (avoid unnecessary GH API calls)
	local current_title
	current_title=$(gh issue view "$health_issue_number" --repo "$repo_slug" --json title --jq '.title' 2>/dev/null || echo "")
	# Strip timestamp for comparison (everything before " at HH:MM UTC")
	local current_stats="${current_title% at [0-9][0-9]:[0-9][0-9] UTC}"
	local new_stats="${health_title% at [0-9][0-9]:[0-9][0-9] UTC}"
	if [[ "$current_stats" != "$new_stats" ]]; then
		gh issue edit "$health_issue_number" --repo "$repo_slug" --title "$health_title" >/dev/null 2>&1 || true
		log_verbose "  Phase 8c: Updated health issue title (stats changed)"
	fi

	log_verbose "  Phase 8c: Updated queue health issue #$health_issue_number"
	return 0
}

#######################################
# Find GitHub issue number for a task from TODO.md (t164)
# Outputs the issue number on stdout, empty if not found.
# $1: task_id
# $2: project_root (optional, default: find_project_root)
#######################################
find_task_issue_number() {
	local task_id="${1:-}"
	local project_root="${2:-}"

	if [[ -z "$task_id" ]]; then
		return 0
	fi

	# Escape dots in task_id for regex (e.g. t128.10 -> t128\.10)
	local task_id_escaped
	task_id_escaped=$(printf '%s' "$task_id" | sed 's/\./\\./g')

	if [[ -z "$project_root" ]]; then
		project_root=$(find_project_root 2>/dev/null || echo ".")
	fi

	local todo_file="$project_root/TODO.md"
	if [[ -f "$todo_file" ]]; then
		local task_line
		task_line=$(grep -E "^[[:space:]]*- \[.\] ${task_id_escaped} " "$todo_file" | head -1 || echo "")
		echo "$task_line" | grep -oE 'ref:GH#[0-9]+' | head -1 | sed 's/ref:GH#//' || echo ""
	fi
	return 0
}

#######################################
# Get the identity string for task claiming (t165)
# Priority: AIDEVOPS_IDENTITY env > GitHub username (cached) > user@hostname
# The GitHub username is preferred because TODO.md assignees typically use
# GitHub usernames (e.g., assignee:marcusquinn), not user@host format.
#######################################
get_aidevops_identity() {
	if [[ -n "${AIDEVOPS_IDENTITY:-}" ]]; then
		echo "$AIDEVOPS_IDENTITY"
		return 0
	fi

	# Try GitHub username (cached for the session to avoid repeated API calls)
	# Validate: must be a simple alphanumeric string (not JSON error like {"message":"..."})
	if [[ -z "${_CACHED_GH_USERNAME:-}" ]]; then
		local gh_user=""
		gh_user=$(gh api user --jq '.login' 2>/dev/null || echo "")
		if [[ -n "$gh_user" && "$gh_user" =~ ^[A-Za-z0-9._-]+$ ]]; then
			_CACHED_GH_USERNAME="$gh_user"
		fi
	fi
	if [[ -n "${_CACHED_GH_USERNAME:-}" ]]; then
		echo "$_CACHED_GH_USERNAME"
		return 0
	fi

	local user host
	user=$(whoami 2>/dev/null || echo "unknown")
	host=$(hostname -s 2>/dev/null || echo "local")
	echo "${user}@${host}"
	return 0
}

#######################################
# Get the assignee: value from a task line in TODO.md (t165, t1017)
# Outputs the assignee identity string, empty if unassigned.
# Only matches assignee: as a metadata field (preceded by space, not inside
# backticks or description text). Uses last occurrence to avoid matching
# assignee: mentioned in task description prose.
# $1: task_id  $2: todo_file path
#######################################
get_task_assignee() {
	local task_id="$1"
	local todo_file="$2"

	if [[ ! -f "$todo_file" ]]; then
		return 0
	fi

	local task_id_escaped
	task_id_escaped=$(printf '%s' "$task_id" | sed 's/\./\\./g')

	local task_line
	task_line=$(grep -E "^[[:space:]]*- \[.\] ${task_id_escaped} " "$todo_file" | head -1 || echo "")
	if [[ -z "$task_line" ]]; then
		return 0
	fi

	# Extract the metadata suffix after the last tag/field marker.
	# Real assignee: fields appear in the metadata tail (after #tags, ~estimate, model:, ref:, etc.)
	# not inside description prose or backtick-quoted code.
	# Strategy: find all assignee:value matches, take the LAST one (metadata fields are appended
	# at the end, description text comes first). Also reject matches inside backticks.
	local assignee=""
	# Strip backtick-quoted segments to avoid matching `assignee:foo` in descriptions
	local stripped_line
	stripped_line=$(echo "$task_line" | sed 's/`[^`]*`//g')
	# Take the last assignee:value match (metadata fields are at the end of the line)
	assignee=$(echo "$stripped_line" | grep -oE ' assignee:[A-Za-z0-9._@-]+' | tail -1 | sed 's/^ *assignee://' || echo "")
	echo "$assignee"
	return 0
}

#######################################
# Claim a task (t165)
# Primary: TODO.md assignee: field (provider-agnostic, offline-capable)
# Optional: sync to GitHub Issue assignee if ref:GH# exists and gh is available
#######################################
cmd_claim() {
	local task_id="${1:-}"
	local explicit_root="${2:-}"

	if [[ -z "$task_id" ]]; then
		log_error "Usage: supervisor-helper.sh claim <task_id> [project_root]"
		return 1
	fi

	local project_root
	if [[ -n "$explicit_root" && -f "$explicit_root/TODO.md" ]]; then
		project_root="$explicit_root"
	else
		project_root=$(find_project_root 2>/dev/null || echo "")
		# Fallback: look up repo from task DB record (needed for cron/non-interactive)
		if [[ -z "$project_root" || ! -f "$project_root/TODO.md" ]]; then
			local db_repo=""
			db_repo=$(db "$SUPERVISOR_DB" "SELECT repo FROM tasks WHERE id = '$(sql_escape "$task_id")';" 2>/dev/null || echo "")
			if [[ -n "$db_repo" && -f "$db_repo/TODO.md" ]]; then
				project_root="$db_repo"
			fi
		fi
	fi
	local todo_file="$project_root/TODO.md"

	if [[ ! -f "$todo_file" ]]; then
		log_error "TODO.md not found at $todo_file"
		return 1
	fi

	local identity
	identity=$(get_aidevops_identity)

	# Validate identity is safe for sed interpolation (no newlines, pipes, or JSON)
	if [[ -z "$identity" || "$identity" == *$'\n'* || "$identity" == *"{"* ]]; then
		log_error "Invalid identity for claim: '${identity:0:40}...' — check gh auth or set AIDEVOPS_IDENTITY"
		return 1
	fi

	# Check current assignee in TODO.md
	local current_assignee
	current_assignee=$(get_task_assignee "$task_id" "$todo_file")

	if [[ -n "$current_assignee" ]]; then
		# Use check_task_claimed for consistent fuzzy matching (handles
		# username vs user@host mismatches)
		local claimed_other=""
		claimed_other=$(check_task_claimed "$task_id" "$project_root" 2>/dev/null) || true
		if [[ -z "$claimed_other" ]]; then
			log_info "$task_id already claimed by you (assignee:$current_assignee)"
			return 0
		fi
		log_error "$task_id is claimed by assignee:$current_assignee"
		return 1
	fi

	# Verify task exists and is open (supports both top-level and indented subtasks)
	local task_id_escaped
	task_id_escaped=$(printf '%s' "$task_id" | sed 's/\./\\./g')
	local task_line
	task_line=$(grep -E "^[[:space:]]*- \[ \] ${task_id_escaped} " "$todo_file" | head -1 || echo "")
	if [[ -z "$task_line" ]]; then
		log_error "Task $task_id not found as open in $todo_file"
		return 1
	fi

	# Add assignee:identity and started:ISO to the task line
	local now
	now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	local line_num
	line_num=$(grep -nE "^[[:space:]]*- \[ \] ${task_id_escaped} " "$todo_file" | head -1 | cut -d: -f1)
	if [[ -z "$line_num" ]]; then
		log_error "Could not find line number for $task_id"
		return 1
	fi

	# Escape identity for safe sed interpolation (handles . / & \ in user@host)
	local identity_esc
	identity_esc=$(printf '%s' "$identity" | sed -e 's/[\/&.\\]/\\&/g')

	# Insert assignee: and started: before logged: or at end of metadata
	local new_line
	if echo "$task_line" | grep -qE 'logged:'; then
		new_line=$(echo "$task_line" | sed -E "s/( logged:)/ assignee:${identity_esc} started:${now}\1/")
	else
		new_line="${task_line} assignee:${identity} started:${now}"
	fi
	sed_inplace "${line_num}s|.*|${new_line}|" "$todo_file"

	# Commit and push (optimistic lock — push failure = someone else claimed first)
	if commit_and_push_todo "$project_root" "chore: claim $task_id by assignee:$identity"; then
		log_success "Claimed $task_id (assignee:$identity, started:$now)"
	else
		# Push failed — check if someone else claimed
		git -C "$project_root" checkout -- TODO.md 2>/dev/null || true
		git -C "$project_root" pull --rebase 2>/dev/null || true
		local new_assignee
		new_assignee=$(get_task_assignee "$task_id" "$todo_file")
		if [[ -n "$new_assignee" && "$new_assignee" != "$identity" ]]; then
			log_error "$task_id was claimed by assignee:$new_assignee (race condition)"
			return 1
		fi
		log_warn "Claimed locally but push failed — will retry on next pulse"
	fi

	# Optional: sync to GitHub Issue assignee (bi-directional sync layer)
	sync_claim_to_github "$task_id" "$project_root" "claim"
	return 0
}

#######################################
# Release a claimed task (t165)
# Primary: TODO.md remove assignee:
# Optional: sync to GitHub Issue
#######################################
cmd_unclaim() {
	local task_id=""
	local explicit_root=""
	local force=false

	# Parse arguments (t1017: support --force flag)
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--force) force=true ;;
		-*)
			log_error "Unknown option: $1"
			return 1
			;;
		*)
			if [[ -z "$task_id" ]]; then
				task_id="$1"
			elif [[ -z "$explicit_root" ]]; then
				explicit_root="$1"
			fi
			;;
		esac
		shift
	done

	if [[ -z "$task_id" ]]; then
		log_error "Usage: supervisor-helper.sh unclaim <task_id> [project_root] [--force]"
		return 1
	fi

	local project_root
	if [[ -n "$explicit_root" && -f "$explicit_root/TODO.md" ]]; then
		project_root="$explicit_root"
	else
		project_root=$(find_project_root 2>/dev/null || echo "")
		# Fallback: look up repo from task DB record (needed for cron/non-interactive)
		if [[ -z "$project_root" || ! -f "$project_root/TODO.md" ]]; then
			local db_repo=""
			db_repo=$(db "$SUPERVISOR_DB" "SELECT repo FROM tasks WHERE id = '$(sql_escape "$task_id")';" 2>/dev/null || echo "")
			if [[ -n "$db_repo" && -f "$db_repo/TODO.md" ]]; then
				project_root="$db_repo"
			fi
		fi
	fi
	local todo_file="$project_root/TODO.md"

	if [[ ! -f "$todo_file" ]]; then
		log_error "TODO.md not found at $todo_file"
		return 1
	fi

	local identity
	identity=$(get_aidevops_identity)

	local current_assignee
	current_assignee=$(get_task_assignee "$task_id" "$todo_file")

	if [[ -z "$current_assignee" ]]; then
		log_info "$task_id is not claimed"
		return 0
	fi

	# Use check_task_claimed for consistent fuzzy matching (t1017)
	local claimed_other=""
	claimed_other=$(check_task_claimed "$task_id" "$project_root" 2>/dev/null) || true
	if [[ -n "$claimed_other" ]]; then
		if [[ "$force" == "true" ]]; then
			log_warn "Force-unclaiming $task_id from assignee:$current_assignee (you: assignee:$identity)"
		else
			log_error "$task_id is claimed by assignee:$current_assignee, not by you (assignee:$identity). Use --force to override."
			return 1
		fi
	fi

	# Remove assignee:identity and started:... from the task line
	local task_id_escaped
	task_id_escaped=$(printf '%s' "$task_id" | sed 's/\./\\./g')
	local line_num
	line_num=$(grep -nE "^[[:space:]]*- \[.\] ${task_id_escaped} " "$todo_file" | head -1 | cut -d: -f1)
	if [[ -z "$line_num" ]]; then
		log_error "Could not find line number for $task_id"
		return 1
	fi

	local task_line
	task_line=$(sed -n "${line_num}p" "$todo_file")
	local new_line
	# Remove assignee:value and started:value
	# Use character class pattern (no identity interpolation needed — matches any assignee)
	new_line=$(echo "$task_line" | sed -E "s/ ?assignee:[A-Za-z0-9._@-]+//; s/ ?started:[0-9T:Z-]+//")
	sed_inplace "${line_num}s|.*|${new_line}|" "$todo_file"

	if commit_and_push_todo "$project_root" "chore: unclaim $task_id (released by assignee:$identity)"; then
		log_success "Released $task_id (unclaimed by assignee:$identity)"
	else
		log_warn "Unclaimed locally but push failed — will retry on next pulse"
	fi

	# Optional: sync to GitHub Issue
	sync_claim_to_github "$task_id" "$project_root" "unclaim"
	return 0
}

#######################################
# Check if a task is claimed by someone else (t165)
# Primary: TODO.md assignee: field (instant, offline)
# Returns 0 if free or claimed by self, 1 if claimed by another.
# Outputs the assignee on stdout if claimed by another.
#######################################
# check_task_already_done() — pre-dispatch verification
# Checks git history for evidence that a task was already completed.
# Returns 0 (true) if task appears done, 1 (false) if not.
# Searches for: (1) commits with task ID in message, (2) TODO.md [x] marker,
# (3) merged PR references. Fast path: git log grep is O(log n) on packed refs.
check_task_already_done() {
	local task_id="${1:-}"
	local project_root="${2:-.}"

	if [[ -z "$task_id" ]]; then
		return 1
	fi

	# Check 1: Is the task already marked [x] in TODO.md?
	# IMPORTANT: TODO.md may contain the same task ID in multiple sections:
	# - Active task list (authoritative — near the top)
	# - Completed plan archive (historical — further down, from earlier iterations)
	# We must check the FIRST occurrence only. If the first match is [x], it's done.
	# If the first match is [ ] or [-], it's NOT done (even if a later [x] exists).
	local todo_file="$project_root/TODO.md"
	if [[ -f "$todo_file" ]]; then
		local first_match=""
		first_match=$(grep -E "^\s*- \[(x| |-)\] ${task_id}[[:space:]]" "$todo_file" 2>/dev/null | head -1) || true
		if [[ -n "$first_match" ]]; then
			# Extract ONLY the checkbox at the start of the line, not [x] anywhere in description
			local checkbox=""
			checkbox=$(printf '%s' "$first_match" | sed -n 's/^[[:space:]]*- \[\(.\)\].*/\1/p')
			if [[ "$checkbox" == "x" ]]; then
				log_info "Pre-dispatch check: $task_id is marked [x] in TODO.md (first occurrence)" >&2
				return 0
			else
				# First occurrence is [ ] or [-] — task is NOT done, skip further checks
				log_info "Pre-dispatch check: $task_id is [ ] in TODO.md (first occurrence — ignoring any later [x] entries)" >&2
				return 1
			fi
		fi
	fi

	# Check 2: Are there merged commits referencing this task ID?
	# IMPORTANT: Use word-boundary matching to prevent t020 matching t020.6.
	# Escaped task_id for regex: dots become literal dots.
	local escaped_task_regex
	escaped_task_regex=$(printf '%s' "$task_id" | sed 's/\./\\./g')
	# grep -w uses word boundaries but dots aren't word chars, so for subtask IDs
	# like t020.1 we need a custom boundary: task_id followed by non-digit or EOL.
	# This prevents t020 from matching t020.1, t020.2, etc.
	local boundary_pattern="${task_id}([^.0-9]|$)"

	local commit_count=0
	commit_count=$(git -C "$project_root" log --oneline -500 --all --grep="$task_id" 2>/dev/null |
		grep -cE "$boundary_pattern" 2>/dev/null) || true
	if [[ "$commit_count" -gt 0 ]]; then
		# Verify at least one commit looks like a REAL completion:
		# Must have a PR merge reference "(#NNN)" AND the exact task ID.
		# Exclude: "add tNNN", "claim tNNN", "mark tNNN blocked", "queue tNNN"
		local completion_evidence=""
		completion_evidence=$(git -C "$project_root" log --oneline -500 --all --grep="$task_id" 2>/dev/null |
			grep -E "$boundary_pattern" |
			grep -iE "\(#[0-9]+\)|PR #[0-9]+ merged" |
			grep -ivE "add ${task_id}|claim ${task_id}|mark ${task_id}|queue ${task_id}|blocked" |
			head -1) || true
		if [[ -n "$completion_evidence" ]]; then
			log_info "Pre-dispatch check: $task_id has completion evidence: $completion_evidence" >&2
			return 0
		fi
	fi

	# Check 3: Does a merged PR exist for this task?
	# Only check if gh CLI is available and authenticated (cached check).
	# Use exact task ID in title search to prevent substring matches.
	# IMPORTANT: gh pr list --repo requires OWNER/REPO slug, not a local path (t224).
	if command -v gh &>/dev/null && check_gh_auth 2>/dev/null; then
		local repo_slug=""
		repo_slug=$(detect_repo_slug "$project_root" 2>/dev/null) || true
		if [[ -n "$repo_slug" ]]; then
			local pr_count=0
			pr_count=$(gh pr list --repo "$repo_slug" --state merged --search "\"$task_id\" in:title" --limit 1 --json number --jq 'length' 2>/dev/null) || true
			if [[ "$pr_count" -gt 0 ]]; then
				log_info "Pre-dispatch check: $task_id has a merged PR on GitHub" >&2
				return 0
			fi
		fi
	fi

	return 1
}

#######################################
# was_previously_worked() — detect tasks that had prior dispatch cycles (t1008)
# Checks the state_log for evidence that a task was previously dispatched,
# ran, and then returned to queued (via retry, blocked->queued, failed->queued,
# or quality-gate escalation). These tasks should get a lightweight verification
# worker instead of a full implementation worker, saving ~$0.80 per dispatch.
#
# Returns:
#   0 = previously worked (should use verify dispatch)
#   1 = fresh task (use normal dispatch)
#
# Output (stdout): reason string if previously worked, empty if fresh
#######################################
was_previously_worked() {
	local task_id="${1:-}"

	if [[ -z "$task_id" ]]; then
		return 1
	fi

	ensure_db

	local escaped_id
	escaped_id=$(sql_escape "$task_id")

	# Check 1: Has this task been dispatched before?
	# A task that was dispatched at least once has a state_log entry for
	# queued->dispatched. If it's back in queued now, it was re-queued.
	local prior_dispatch_count=0
	prior_dispatch_count=$(db "$SUPERVISOR_DB" "
		SELECT COUNT(*) FROM state_log
		WHERE task_id = '$escaped_id'
		AND to_state = 'dispatched';
	" 2>/dev/null) || prior_dispatch_count=0

	if [[ "$prior_dispatch_count" -gt 0 ]]; then
		# Check 2: Does the task have retries > 0? (direct evidence of re-queue)
		local retry_count=0
		retry_count=$(db "$SUPERVISOR_DB" "
			SELECT COALESCE(retries, 0) FROM tasks WHERE id = '$escaped_id';
		" 2>/dev/null) || retry_count=0

		if [[ "$retry_count" -gt 0 ]]; then
			echo "retry_count:$retry_count,prior_dispatches:$prior_dispatch_count"
			return 0
		fi

		# Check 3: Was it ever in a terminal-ish state (evaluating, blocked, failed)
		# before being re-queued? This catches quality-gate escalations and manual resets.
		local prior_eval_count=0
		prior_eval_count=$(db "$SUPERVISOR_DB" "
			SELECT COUNT(*) FROM state_log
			WHERE task_id = '$escaped_id'
			AND to_state IN ('evaluating', 'blocked', 'failed', 'retrying');
		" 2>/dev/null) || prior_eval_count=0

		if [[ "$prior_eval_count" -gt 0 ]]; then
			echo "prior_dispatches:$prior_dispatch_count,prior_evaluations:$prior_eval_count"
			return 0
		fi
	fi

	# Check 4: Does a branch with commits already exist for this task?
	# This catches cases where a worker created commits but the session died
	# before the supervisor could evaluate it (orphaned work).
	local task_branch="feature/${task_id}"
	local repo
	repo=$(db "$SUPERVISOR_DB" "SELECT repo FROM tasks WHERE id = '$escaped_id';" 2>/dev/null) || repo="."
	local branch_commits=0
	branch_commits=$(git -C "${repo:-.}" log --oneline "origin/$task_branch" --not origin/main 2>/dev/null | wc -l | tr -d ' ') || branch_commits=0

	if [[ "$branch_commits" -gt 0 ]]; then
		echo "existing_branch_commits:$branch_commits"
		return 0
	fi

	return 1
}

#######################################
# check_task_staleness() — pre-dispatch staleness detection (t312)
# Analyses a task description against the current codebase to detect
# tasks whose premise is no longer valid (removed features, renamed
# files, contradicting commits).
#
# Returns:
#   0 = STALE — task is clearly outdated (cancel it)
#   1 = CURRENT — task appears valid (safe to dispatch)
#   2 = UNCERTAIN — staleness signals present but inconclusive
#       (comment on GH issue, remove #auto-dispatch, await human review)
#
# Output (stdout): staleness reason if stale/uncertain, empty if current
#######################################
check_task_staleness() {
	# Allow bypassing staleness check via env var (t314: for create tasks that reference non-existent files)
	if [[ "${SUPERVISOR_SKIP_STALENESS:-false}" == "true" ]]; then
		return 1 # Assume current
	fi

	local task_id="${1:-}"
	local task_description="${2:-}"
	local project_root="${3:-.}"

	if [[ -z "$task_id" || -z "$task_description" ]]; then
		return 1 # Can't check without description — assume current
	fi

	local staleness_signals=0
	local staleness_reasons=""

	# --- Signal 1: Extract feature/tool names and check for removal commits ---
	# Pattern: hyphenated names with 2+ segments (widget-helper, oh-my-opencode, etc.)
	local feature_names=""
	feature_names=$(printf '%s' "$task_description" |
		grep -oE '[a-zA-Z][a-zA-Z0-9]*-[a-zA-Z][a-zA-Z0-9]+(-[a-zA-Z][a-zA-Z0-9]+)*' |
		sort -u) || true

	# Also extract quoted terms
	local quoted_terms=""
	quoted_terms=$(printf '%s' "$task_description" |
		grep -oE '"[^"]{3,}"' | tr -d '"' | sort -u) || true

	local all_terms=""
	all_terms=$(printf '%s\n%s' "$feature_names" "$quoted_terms" |
		grep -v '^$' | sort -u) || true

	if [[ -n "$all_terms" ]]; then
		while IFS= read -r term; do
			[[ -z "$term" ]] && continue

			local removal_commits=""
			removal_commits=$(git -C "$project_root" log --oneline -200 \
				--grep="$term" 2>/dev/null |
				grep -iE "remov|delet|drop|deprecat|clean.?up|refactor.*remov" |
				head -3) || true

			if [[ -n "$removal_commits" ]]; then
				local codebase_refs=0
				codebase_refs=$(git -C "$project_root" grep -rl "$term" \
					-- '*.sh' '*.md' '*.mjs' '*.ts' '*.json' 2>/dev/null |
					grep -cv 'TODO.md\|CHANGELOG.md\|VERIFY.md\|PLANS.md\|verification\|todo/' \
						2>/dev/null) || true

				local newest_commit_is_removal=false
				local newest_commit=""
				newest_commit=$(git -C "$project_root" log --oneline -1 \
					--grep="$term" 2>/dev/null) || true

				if [[ -n "$newest_commit" ]]; then
					if printf '%s' "$newest_commit" |
						grep -qiE "remov|delet|drop|deprecat|clean.?up"; then
						newest_commit_is_removal=true
					fi
				fi

				local active_refs=0
				if [[ "$codebase_refs" -gt 0 ]]; then
					active_refs=$(git -C "$project_root" grep -rn "$term" \
						-- '*.sh' '*.md' '*.mjs' '*.ts' '*.json' 2>/dev/null |
						grep -v 'TODO.md\|CHANGELOG.md\|VERIFY.md\|PLANS.md\|verification\|todo/' |
						grep -icv 'remov\|delet\|deprecat\|clean.up\|no longer\|was removed\|dropped\|legacy\|historical\|formerly\|previously\|used to\|compat\|detect\|OMOC\|Phase 0' \
							2>/dev/null) || true
				fi

				local first_removal=""
				first_removal=$(printf '%s' "$removal_commits" | head -1)

				if [[ "$newest_commit_is_removal" == "true" && "$active_refs" -eq 0 ]]; then
					staleness_signals=$((staleness_signals + 3))
					staleness_reasons="${staleness_reasons}REMOVED: '$term' — most recent commit is a removal (${first_removal}), 0 active refs. "
				elif [[ "$active_refs" -eq 0 ]]; then
					staleness_signals=$((staleness_signals + 3))
					staleness_reasons="${staleness_reasons}REMOVED: '$term' was removed (${first_removal}) with 0 active codebase references. "
				elif [[ "$newest_commit_is_removal" == "true" ]]; then
					staleness_signals=$((staleness_signals + 2))
					staleness_reasons="${staleness_reasons}LIKELY_REMOVED: '$term' — most recent commit is removal (${first_removal}) but $active_refs active refs remain. "
				elif [[ "$active_refs" -le 2 ]]; then
					staleness_signals=$((staleness_signals + 1))
					staleness_reasons="${staleness_reasons}MINIMAL: '$term' has removal commits and only $active_refs active references. "
				fi
			fi
		done <<<"$all_terms"
	fi

	# --- Signal 2: Extract file paths and check existence ---
	local file_refs=""
	file_refs=$(printf '%s' "$task_description" |
		grep -oE '[a-zA-Z0-9_/-]+\.[a-z]{1,4}' |
		grep -vE '^\.' |
		sort -u) || true

	if [[ -n "$file_refs" ]]; then
		local missing_files=0
		local total_files=0
		while IFS= read -r file_ref; do
			[[ -z "$file_ref" ]] && continue
			total_files=$((total_files + 1))

			if ! git -C "$project_root" ls-files --error-unmatch "$file_ref" \
				&>/dev/null 2>&1; then
				local found=false
				for prefix in ".agents/" ".agents/scripts/" ".agents/tools/" ""; do
					if git -C "$project_root" ls-files --error-unmatch \
						"${prefix}${file_ref}" &>/dev/null 2>&1; then
						found=true
						break
					fi
				done
				if [[ "$found" == "false" ]]; then
					missing_files=$((missing_files + 1))
				fi
			fi
		done <<<"$file_refs"

		if [[ "$total_files" -gt 0 && "$missing_files" -gt 0 ]]; then
			local missing_pct=$((missing_files * 100 / total_files))
			if [[ "$missing_pct" -ge 50 ]]; then
				staleness_signals=$((staleness_signals + 2))
				staleness_reasons="${staleness_reasons}MISSING_FILES: $missing_files/$total_files referenced files not found. "
			fi
		fi
	fi

	# --- Signal 3: Check if task's parent feature was already removed ---
	local parent_id=""
	if [[ "$task_id" =~ ^(t[0-9]+)\.[0-9]+$ ]]; then
		parent_id="${BASH_REMATCH[1]}"
		local parent_removal=""
		parent_removal=$(git -C "$project_root" log --oneline -200 \
			--grep="$parent_id" 2>/dev/null |
			grep -iE "remov|delet|drop|deprecat" |
			head -1) || true

		if [[ -n "$parent_removal" ]]; then
			staleness_signals=$((staleness_signals + 1))
			staleness_reasons="${staleness_reasons}PARENT_REMOVED: Parent $parent_id has removal commits: $parent_removal. "
		fi
	fi

	# --- Signal 4: Check for contradicting "already done" patterns ---
	local task_verb=""
	task_verb=$(printf '%s' "$task_description" |
		grep -oE '^(add|create|implement|build|set up|integrate|fix|resolve)' |
		head -1) || true

	if [[ "$task_verb" =~ ^(add|create|implement|build|integrate) ]]; then
		local subject=""
		subject=$(printf '%s' "$task_description" |
			sed -E "s/^(add|create|implement|build|set up|integrate) //i" |
			cut -d' ' -f1-3) || true

		if [[ -n "$subject" ]]; then
			local existing_refs=0
			existing_refs=$(git -C "$project_root" log --oneline -50 \
				--grep="$subject" 2>/dev/null |
				grep -icE "add|creat|implement|built|integrat" 2>/dev/null) || true

			if [[ "$existing_refs" -ge 2 ]]; then
				staleness_signals=$((staleness_signals + 1))
				staleness_reasons="${staleness_reasons}POSSIBLY_DONE: '$subject' has $existing_refs existing implementation commits. "
			fi
		fi
	fi

	# --- Decision: three-tier threshold ---
	if [[ "$staleness_signals" -ge 3 ]]; then
		printf '%s' "$staleness_reasons"
		return 0 # STALE
	elif [[ "$staleness_signals" -eq 2 ]]; then
		printf '%s' "$staleness_reasons"
		return 2 # UNCERTAIN
	fi

	return 1 # CURRENT
}

#######################################
# handle_stale_task() — act on staleness detection result (t312)
# For STALE tasks: cancel in DB
# For UNCERTAIN tasks: comment on GH issue, remove #auto-dispatch from TODO.md
#######################################
handle_stale_task() {
	local task_id="${1:-}"
	local staleness_exit="${2:-1}"
	local staleness_reason="${3:-}"
	local project_root="${4:-.}"

	local escaped_id
	escaped_id=$(sql_escape "$task_id")

	if [[ "$staleness_exit" -eq 0 ]]; then
		# STALE — cancel the task
		log_warn "Task $task_id is STALE — cancelling: $staleness_reason"
		db "$SUPERVISOR_DB" "UPDATE tasks SET status='cancelled', error='Pre-dispatch staleness: ${staleness_reason:0:200}' WHERE id='$escaped_id';"
		return 0

	elif [[ "$staleness_exit" -eq 2 ]]; then
		# UNCERTAIN — comment on GH issue and remove #auto-dispatch
		log_warn "Task $task_id has UNCERTAIN staleness — pausing for review: $staleness_reason"

		# Remove #auto-dispatch from TODO.md
		local todo_file="$project_root/TODO.md"
		if [[ -f "$todo_file" ]]; then
			if grep -q "^[[:space:]]*- \[ \] ${task_id}[[:space:]].*#auto-dispatch" "$todo_file" 2>/dev/null; then
				sed -i.bak "s/\(- \[ \] ${task_id}[[:space:]].*\) #auto-dispatch/\1/" "$todo_file"
				rm -f "${todo_file}.bak"
				log_info "Removed #auto-dispatch from $task_id in TODO.md"

				# Commit the change
				if git -C "$project_root" diff --quiet "$todo_file" 2>/dev/null; then
					log_info "No TODO.md changes to commit"
				else
					git -C "$project_root" add "$todo_file" 2>/dev/null || true
					git -C "$project_root" commit -q -m "chore: pause $task_id — staleness check uncertain, removed #auto-dispatch" 2>/dev/null || true
					git -C "$project_root" push -q 2>/dev/null || true
				fi
			fi
		fi

		# Comment on GitHub issue if ref:GH# exists
		local gh_issue=""
		gh_issue=$(grep "^[[:space:]]*- \[.\] ${task_id}[[:space:]]" "$todo_file" 2>/dev/null |
			grep -oE 'ref:GH#[0-9]+' | grep -oE '[0-9]+' | head -1) || true

		if [[ -n "$gh_issue" ]] && command -v gh &>/dev/null; then
			local repo_slug=""
			repo_slug=$(detect_repo_slug "$project_root" 2>/dev/null) || true
			if [[ -n "$repo_slug" ]]; then
				local comment_body
				comment_body=$(
					cat <<STALENESS_EOF
**Staleness check (t312)**: This task may be outdated. Removing \`#auto-dispatch\` until reviewed.

**Signals detected:**
${staleness_reason}

**Action needed:** Please review whether this task is still relevant. If yes, re-add \`#auto-dispatch\` to the TODO.md entry. If not, mark as \`[-]\` (declined).
STALENESS_EOF
				)

				gh issue comment "$gh_issue" --repo "$repo_slug" \
					--body "$comment_body" 2>/dev/null || true
				log_info "Posted staleness comment on GH#$gh_issue"
			fi
		fi

		# Mark as blocked in DB so it's not re-dispatched
		db "$SUPERVISOR_DB" "UPDATE tasks SET status='blocked', error='Staleness uncertain — awaiting review: ${staleness_reason:0:200}' WHERE id='$escaped_id';" 2>/dev/null || true
		return 0
	fi

	return 1 # CURRENT — no action needed
}

check_task_claimed() {
	local task_id="${1:-}"
	local project_root="${2:-.}"
	local todo_file="$project_root/TODO.md"

	local current_assignee
	current_assignee=$(get_task_assignee "$task_id" "$todo_file")

	# No assignee = free
	if [[ -z "$current_assignee" ]]; then
		return 0
	fi

	local identity
	identity=$(get_aidevops_identity)

	# Exact match = claimed by self
	if [[ "$current_assignee" == "$identity" ]]; then
		return 0
	fi

	# Fuzzy match: assignee might be just a username while identity is user@host,
	# or vice versa. Also check the local username (whoami) and GitHub username.
	local local_user
	local_user=$(whoami 2>/dev/null || echo "")
	local gh_user="${_CACHED_GH_USERNAME:-}"
	local identity_user="${identity%%@*}" # Strip @host portion

	if [[ "$current_assignee" == "$local_user" ]] ||
		[[ "$current_assignee" == "$gh_user" ]] ||
		[[ "$current_assignee" == "$identity_user" ]] ||
		[[ "${current_assignee%%@*}" == "$identity_user" ]]; then
		return 0
	fi

	# Claimed by someone else
	echo "$current_assignee"
	return 1
}

#######################################
# Sync claim/unclaim to GitHub Issue assignee (t165)
# Optional bi-directional sync layer — fails silently if gh unavailable
# or if the task has no ref:GH# in TODO.md. This is a best-effort
# convenience; TODO.md assignee: is the authoritative claim source.
# $1: task_id  $2: project_root  $3: action (claim|unclaim)
#######################################
sync_claim_to_github() {
	local task_id="$1"
	local project_root="$2"
	local action="$3"

	# Skip if gh CLI not available or not authenticated
	command -v gh &>/dev/null || return 0
	check_gh_auth || return 0

	local issue_number
	issue_number=$(find_task_issue_number "$task_id" "$project_root")
	if [[ -z "$issue_number" ]]; then
		return 0
	fi

	local repo_slug
	repo_slug=$(detect_repo_slug "$project_root" 2>/dev/null || echo "")
	if [[ -z "$repo_slug" ]]; then
		return 0
	fi

	ensure_status_labels "$repo_slug"

	if [[ "$action" == "claim" ]]; then
		# t1009: Remove all status labels, add status:claimed
		gh issue edit "$issue_number" --repo "$repo_slug" \
			--add-assignee "@me" \
			--add-label "status:claimed" \
			--remove-label "status:available" --remove-label "status:queued" \
			--remove-label "status:blocked" --remove-label "status:verify-failed" 2>/dev/null || true
	elif [[ "$action" == "unclaim" ]]; then
		local my_login
		my_login=$(gh api user --jq '.login' 2>/dev/null || echo "")
		if [[ -n "$my_login" ]]; then
			# t1009: Remove all status labels, add status:available
			gh issue edit "$issue_number" --repo "$repo_slug" \
				--remove-assignee "$my_login" \
				--add-label "status:available" \
				--remove-label "status:claimed" --remove-label "status:queued" \
				--remove-label "status:blocked" --remove-label "status:verify-failed" 2>/dev/null || true
		fi
	fi
	return 0
}

#######################################
# Create a GitHub issue for a task
# Delegates to issue-sync-helper.sh push tNNN for rich issue bodies (t020.6).
# Returns the issue number on success, empty on failure.
# Also adds ref:GH#N to TODO.md and commits/pushes the change.
# Requires: gh CLI authenticated, repo with GitHub remote
#######################################
create_github_issue() {
	local task_id="$1"
	local description="$2"
	local repo_path="$3"

	# t165: Callers are responsible for gating (cmd_add uses --with-issue flag).
	# This function always attempts creation when called.

	# Verify gh CLI is available and authenticated
	if ! command -v gh &>/dev/null; then
		log_warn "gh CLI not found, skipping GitHub issue creation"
		return 0
	fi

	if ! check_gh_auth; then
		log_warn "gh CLI not authenticated, skipping GitHub issue creation"
		return 0
	fi

	# Detect repo slug from git remote
	local repo_slug
	local remote_url
	remote_url=$(git -C "$repo_path" remote get-url origin 2>/dev/null || echo "")
	remote_url="${remote_url%.git}"
	repo_slug=$(echo "$remote_url" | sed -E 's|.*[:/]([^/]+/[^/]+)$|\1|' || echo "")
	if [[ -z "$repo_slug" ]]; then
		log_warn "Could not detect GitHub repo slug, skipping issue creation"
		return 0
	fi

	# Check if an issue with this task ID prefix already exists
	local existing_issue
	existing_issue=$(gh issue list --repo "$repo_slug" --search "in:title ${task_id}:" --json number --jq '.[0].number' 2>>"$SUPERVISOR_LOG" || echo "")
	if [[ -n "$existing_issue" && "$existing_issue" != "null" ]]; then
		log_info "GitHub issue #${existing_issue} already exists for $task_id"
		echo "$existing_issue"
		return 0
	fi

	# Delegate to issue-sync-helper.sh push tNNN (t020.6: single source of truth)
	# The helper handles: TODO.md parsing, rich body composition, label mapping,
	# issue creation via gh CLI, and adding ref:GH#N to TODO.md.
	local issue_sync_helper="${SCRIPT_DIR}/issue-sync-helper.sh"
	if [[ ! -x "$issue_sync_helper" ]]; then
		log_warn "issue-sync-helper.sh not found at $issue_sync_helper, skipping issue creation"
		return 0
	fi

	log_info "Delegating issue creation to issue-sync-helper.sh for $task_id"
	local push_output
	# Run from repo_path so find_project_root() locates TODO.md
	push_output=$(cd "$repo_path" && "$issue_sync_helper" push "$task_id" --repo "$repo_slug" 2>>"$SUPERVISOR_LOG" || echo "")

	# Extract issue number from push output (format: "[SUCCESS] Created #NNN: title")
	local issue_number
	issue_number=$(echo "$push_output" | grep -oE 'Created #[0-9]+' | grep -oE '[0-9]+' | head -1 || echo "")

	if [[ -z "$issue_number" ]]; then
		log_warn "issue-sync-helper.sh did not return an issue number for $task_id"
		return 0
	fi

	log_success "Created GitHub issue #${issue_number} for $task_id via issue-sync-helper.sh"

	# Update supervisor DB with issue URL
	local escaped_id
	escaped_id=$(sql_escape "$task_id")
	local escaped_url="https://github.com/${repo_slug}/issues/${issue_number}"
	escaped_url=$(sql_escape "$escaped_url")
	db "$SUPERVISOR_DB" "UPDATE tasks SET issue_url = '$escaped_url' WHERE id = '$escaped_id';"

	# issue-sync-helper.sh already added ref:GH#N to TODO.md — commit and push it
	commit_and_push_todo "$repo_path" "chore: add GH#${issue_number} ref to $task_id in TODO.md"

	echo "$issue_number"
	return 0
}

#######################################
# Commit and push VERIFY.md changes after verification (t180.3)
#######################################

#######################################
# Post a comment to GitHub issue when a worker is blocked (t296)
# Extracts the GitHub issue number from TODO.md ref:GH# field
# Posts a comment explaining what's needed and removes auto-dispatch label
# Args: task_id, blocked_reason, repo_path
#######################################
post_blocked_comment_to_github() {
	local task_id="$1"
	local reason="${2:-unknown}"
	local repo_path="$3"

	# Check if gh CLI is available
	if ! command -v gh &>/dev/null; then
		log_warn "gh CLI not available, skipping GitHub issue comment for $task_id"
		return 0
	fi

	# Extract GitHub issue number from TODO.md
	local todo_file="$repo_path/TODO.md"
	if [[ ! -f "$todo_file" ]]; then
		return 0
	fi

	local task_line
	task_line=$(grep -E "^[[:space:]]*- \[.\] ${task_id} " "$todo_file" | head -1 || echo "")
	if [[ -z "$task_line" ]]; then
		return 0
	fi

	local gh_issue_num
	gh_issue_num=$(echo "$task_line" | grep -oE 'ref:GH#[0-9]+' | head -1 | sed 's/ref:GH#//' || echo "")
	if [[ -z "$gh_issue_num" ]]; then
		log_info "No GitHub issue reference found for $task_id, skipping comment"
		return 0
	fi

	# Detect repo slug
	local repo_slug
	repo_slug=$(detect_repo_slug "$repo_path" 2>/dev/null || echo "")
	if [[ -z "$repo_slug" ]]; then
		log_warn "Could not detect repo slug for $repo_path, skipping GitHub comment"
		return 0
	fi

	# Construct the comment body
	local comment_body
	comment_body="**Worker Blocked** 🚧

The automated worker for this task encountered an issue and needs clarification:

**Reason:** ${reason}

**Next Steps:**
1. Review the blocked reason above
2. Provide the missing information or fix the blocking issue
3. Add the \`#auto-dispatch\` tag to the task in TODO.md when ready for the next attempt

The supervisor will automatically retry this task once it's tagged with \`#auto-dispatch\`."

	# Post the comment
	if gh issue comment "$gh_issue_num" --repo "$repo_slug" --body "$comment_body" 2>/dev/null; then
		log_success "Posted blocked comment to GitHub issue #$gh_issue_num"
	else
		log_warn "Failed to post comment to GitHub issue #$gh_issue_num"
	fi

	# Remove auto-dispatch label if it exists
	if gh issue edit "$gh_issue_num" --repo "$repo_slug" --remove-label "auto-dispatch" 2>/dev/null; then
		log_success "Removed auto-dispatch label from GitHub issue #$gh_issue_num"
	else
		# Label might not exist, which is fine
		log_info "auto-dispatch label not present on issue #$gh_issue_num (or removal failed)"
	fi

	return 0
}
