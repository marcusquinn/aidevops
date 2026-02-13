#!/usr/bin/env bash
# batch.sh - Batch and task creation functions
#
# Functions for adding tasks and creating batches


#######################################
# Add a task to the supervisor
#######################################
cmd_add() {
	local task_id="" repo="" description="" model="anthropic/claude-opus-4-6" max_retries=3
	# t165: GH Issue creation is now opt-in (--with-issue), not opt-out.
	# TODO.md is the primary task registry; GH Issues are an optional sync layer.
	# SUPERVISOR_AUTO_ISSUE=true restores the old default for backward compat.
	local create_issue=false

	# First positional arg is task_id
	if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
		task_id="$1"
		shift
	fi

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--repo)
			[[ $# -lt 2 ]] && {
				log_error "--repo requires a value"
				return 1
			}
			repo="$2"
			shift 2
			;;
		--description)
			[[ $# -lt 2 ]] && {
				log_error "--description requires a value"
				return 1
			}
			description="$2"
			shift 2
			;;
		--model)
			[[ $# -lt 2 ]] && {
				log_error "--model requires a value"
				return 1
			}
			model="$2"
			shift 2
			;;
		--max-retries)
			[[ $# -lt 2 ]] && {
				log_error "--max-retries requires a value"
				return 1
			}
			max_retries="$2"
			shift 2
			;;
		--with-issue)
			create_issue=true
			shift
			;;
		--no-issue)
			create_issue=false
			shift
			;; # Kept for backward compat (now the default)
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	# Backward compat: SUPERVISOR_AUTO_ISSUE=true restores old default
	if [[ "${SUPERVISOR_AUTO_ISSUE:-false}" == "true" && "$create_issue" == "false" ]]; then
		create_issue=true
	fi

	if [[ -z "$task_id" ]]; then
		log_error "Usage: supervisor-helper.sh add <task_id> [--repo path] [--description \"desc\"]"
		return 1
	fi

	# Default repo to current directory
	if [[ -z "$repo" ]]; then
		repo="$(pwd)"
	fi

	# Try to look up description and model: field from TODO.md if not provided
	local todo_file="$repo/TODO.md"
	if [[ -z "$description" && -f "$todo_file" ]]; then
		description=$(grep -E "^[[:space:]]*- \[( |x|-)\] $task_id " "$todo_file" 2>/dev/null | head -1 | sed -E 's/^[[:space:]]*- \[( |x|-)\] [^ ]* //' || true)
	fi

	# t246: Extract model:<tier> from TODO.md task line if --model wasn't explicitly set.
	# This allows users to pin a task to a specific tier in TODO.md, e.g.:
	#   - [ ] t001 Update readme #docs model:sonnet ~30m
	if [[ "$model" == "anthropic/claude-opus-4-6" && -f "$todo_file" ]]; then
		local todo_line
		todo_line=$(grep -E "^[[:space:]]*- \[( |x|-)\] $task_id " "$todo_file" 2>/dev/null | head -1 || true)
		if [[ -n "$todo_line" ]]; then
			local todo_model
			todo_model=$(echo "$todo_line" | grep -oE 'model:[a-zA-Z0-9/_.-]+' | head -1 | sed 's/^model://' || true)
			if [[ -n "$todo_model" ]]; then
				model="$todo_model"
				log_info "Task $task_id: model override from TODO.md: $model"
			fi
		fi
	fi

	# Model routing safeguard: auto-upgrade when explicit model conflicts with complexity classifier
	# This catches tasks tagged model:sonnet that are actually complex enough for opus.
	# Complex tasks on weak models waste compute and fail — auto-upgrade is mandatory.
	if [[ -n "$description" && "$model" != "anthropic/claude-opus-4-6" && "$model" != "opus" ]]; then
		local auto_tier
		auto_tier=$(classify_task_complexity "$description" "" 2>>"$SUPERVISOR_LOG" || echo "")
		if [[ "$auto_tier" == "opus" ]]; then
			log_warn "Task $task_id: explicit model:$model but classifier recommends opus — auto-upgrading"
			# Auto-upgrade to opus when classifier disagrees with explicit sonnet (safety-first)
			model="opus"
			log_info "Task $task_id: auto-upgraded to model:opus (classifier override)"
		fi
	fi

	ensure_db

	# Check if task already exists
	local existing
	existing=$(db "$SUPERVISOR_DB" "SELECT status FROM tasks WHERE id = '$(sql_escape "$task_id")';")
	if [[ -n "$existing" ]]; then
		log_warn "Task $task_id already exists (status: $existing)"
		return 1
	fi

	# Pre-add check: prevent re-queuing tasks that already have a merged PR (t224).
	# This catches tasks completed outside the supervisor (fresh DB, DB reset, etc.)
	# that would otherwise be re-added and re-dispatched, wasting compute.
	if check_task_already_done "$task_id" "$repo"; then
		log_warn "Task $task_id already completed (merged PR or [x] in TODO.md) — skipping add"
		return 1
	fi

	local escaped_id
	escaped_id=$(sql_escape "$task_id")
	local escaped_repo
	escaped_repo=$(sql_escape "$repo")
	local escaped_desc
	escaped_desc=$(sql_escape "$description")
	local escaped_model
	escaped_model=$(sql_escape "$model")

	db "$SUPERVISOR_DB" "
        INSERT INTO tasks (id, repo, description, model, max_retries)
        VALUES ('$escaped_id', '$escaped_repo', '$escaped_desc', '$escaped_model', $max_retries);
    "

	# Log the initial state
	db "$SUPERVISOR_DB" "
        INSERT INTO state_log (task_id, from_state, to_state, reason)
        VALUES ('$escaped_id', '', 'queued', 'Task added to supervisor');
    "

	log_success "Added task: $task_id (repo: $repo)"
	if [[ -n "$description" ]]; then
		log_info "Description: $(echo "$description" | head -c 80)"
	fi

	# Create GitHub issue only if explicitly requested (t165: opt-in, not default)
	# Use --with-issue flag or SUPERVISOR_AUTO_ISSUE=true env var
	# t020.6: create_github_issue delegates to issue-sync-helper.sh which also
	# adds ref:GH#N to TODO.md and commits/pushes — no separate step needed.
	if [[ "$create_issue" == "true" ]]; then
		create_github_issue "$task_id" "$description" "$repo"
	fi

	# t1009: Set status:queued label on the GitHub issue (if it exists)
	# This is the initial state — cmd_transition() handles subsequent transitions.
	sync_issue_status_label "$task_id" "queued" "" 2>>"${SUPERVISOR_LOG:-/dev/null}" || true

	return 0
}

#######################################
# Create or manage a batch
#######################################
cmd_batch() {
	local name="" concurrency=4 max_concurrency=0 tasks="" max_load_factor=2
	local release_on_complete=0 release_type="patch" skip_quality_gate=0

	# First positional arg is batch name
	if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
		name="$1"
		shift
	fi

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--concurrency)
			[[ $# -lt 2 ]] && {
				log_error "--concurrency requires a value"
				return 1
			}
			concurrency="$2"
			shift 2
			;;
		--max-concurrency)
			[[ $# -lt 2 ]] && {
				log_error "--max-concurrency requires a value"
				return 1
			}
			max_concurrency="$2"
			shift 2
			;;
		--tasks)
			[[ $# -lt 2 ]] && {
				log_error "--tasks requires a value"
				return 1
			}
			tasks="$2"
			shift 2
			;;
		--max-load)
			[[ $# -lt 2 ]] && {
				log_error "--max-load requires a value"
				return 1
			}
			max_load_factor="$2"
			shift 2
			;;
		--release-on-complete)
			release_on_complete=1
			shift
			;;
		--release-type)
			[[ $# -lt 2 ]] && {
				log_error "--release-type requires a value"
				return 1
			}
			release_type="$2"
			shift 2
			;;
		--skip-quality-gate)
			skip_quality_gate=1
			shift
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$name" ]]; then
		log_error "Usage: supervisor-helper.sh batch <name> [--concurrency N] [--max-concurrency N] [--tasks \"t001,t002\"] [--release-on-complete] [--release-type patch|minor|major] [--skip-quality-gate]"
		return 1
	fi

	# Validate release_type
	case "$release_type" in
	major | minor | patch) ;;
	*)
		log_error "Invalid release type: $release_type (must be major, minor, or patch)"
		return 1
		;;
	esac

	ensure_db

	local batch_id
	batch_id="batch-$(date +%Y%m%d%H%M%S)-$$"
	local escaped_id
	escaped_id=$(sql_escape "$batch_id")
	local escaped_name
	escaped_name=$(sql_escape "$name")
	local escaped_release_type
	escaped_release_type=$(sql_escape "$release_type")

	db "$SUPERVISOR_DB" "
        INSERT INTO batches (id, name, concurrency, max_concurrency, max_load_factor, release_on_complete, release_type, skip_quality_gate)
        VALUES ('$escaped_id', '$escaped_name', $concurrency, $max_concurrency, $max_load_factor, $release_on_complete, '$escaped_release_type', $skip_quality_gate);
    "

	local release_info=""
	if [[ "$release_on_complete" -eq 1 ]]; then
		release_info=", release: $release_type on complete"
	fi
	local max_conc_info=""
	if [[ "$max_concurrency" -gt 0 ]]; then
		max_conc_info=", max: $max_concurrency"
	else
		max_conc_info=", max: auto"
	fi
	local quality_gate_info=""
	if [[ "$skip_quality_gate" -eq 1 ]]; then
		quality_gate_info=", quality-gate: skipped"
	fi
	log_success "Created batch: $name (id: $batch_id, concurrency: $concurrency${max_conc_info}, max-load: $max_load_factor${release_info}${quality_gate_info})"

	# Add tasks to batch if provided
	if [[ -n "$tasks" ]]; then
		local position=0
		local -a task_array
		IFS=',' read -ra task_array <<<"$tasks"
		for task_id in "${task_array[@]}"; do
			task_id=$(echo "$task_id" | tr -d ' ')

			# Ensure task exists in tasks table (auto-add if not)
			local task_exists
			task_exists=$(db "$SUPERVISOR_DB" "SELECT count(*) FROM tasks WHERE id = '$(sql_escape "$task_id")';")
			if [[ "$task_exists" -eq 0 ]]; then
				cmd_add "$task_id"
			fi

			local escaped_task
			escaped_task=$(sql_escape "$task_id")
			db "$SUPERVISOR_DB" "
                INSERT OR IGNORE INTO batch_tasks (batch_id, task_id, position)
                VALUES ('$escaped_id', '$escaped_task', $position);
            "
			position=$((position + 1))
		done
		log_info "Added ${#task_array[@]} tasks to batch"
	fi

	echo "$batch_id"
	return 0
}
