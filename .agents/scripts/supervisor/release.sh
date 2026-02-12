#!/usr/bin/env bash
# release.sh - Supervisor release management functions
# Part of the AI DevOps Framework supervisor module

# Trigger batch release (t128.10)
# Runs version-manager.sh to bump version, update changelog, tag, and create GitHub release
trigger_batch_release() {
	local batch_id="$1"
	local release_type="$2"
	local repo="$3"

	local version_manager="${SCRIPT_DIR}/version-manager.sh"
	if [[ ! -x "$version_manager" ]]; then
		log_error "version-manager.sh not found or not executable: $version_manager"
		return 1
	fi

	if [[ -z "$repo" || ! -d "$repo" ]]; then
		log_error "Invalid repo path for batch release: $repo"
		return 1
	fi

	# Validate release_type
	case "$release_type" in
	major | minor | patch) ;;
	*)
		log_error "Invalid release type for batch $batch_id: $release_type"
		return 1
		;;
	esac

	local escaped_batch
	escaped_batch=$(sql_escape "$batch_id")
	local batch_name
	batch_name=$(db "$SUPERVISOR_DB" "SELECT name FROM batches WHERE id = '$escaped_batch';" 2>/dev/null || echo "$batch_id")

	# Gather batch stats for the release log
	local total_tasks complete_count failed_count
	total_tasks=$(db "$SUPERVISOR_DB" "
        SELECT count(*) FROM batch_tasks WHERE batch_id = '$escaped_batch';
    ")
	complete_count=$(db "$SUPERVISOR_DB" "
        SELECT count(*) FROM batch_tasks bt JOIN tasks t ON bt.task_id = t.id
        WHERE bt.batch_id = '$escaped_batch' AND t.status IN ('complete', 'deployed', 'merged');
    ")
	failed_count=$(db "$SUPERVISOR_DB" "
        SELECT count(*) FROM batch_tasks bt JOIN tasks t ON bt.task_id = t.id
        WHERE bt.batch_id = '$escaped_batch' AND t.status IN ('failed', 'blocked');
    ")

	log_info "Triggering $release_type release for batch $batch_name ($complete_count/$total_tasks tasks complete, $failed_count failed)"

	# Release must run from the main repo on the main branch
	# version-manager.sh handles: bump, update files, changelog, tag, push, GitHub release
	local release_log
	release_log="$SUPERVISOR_DIR/logs/release-${batch_id}-$(date +%Y%m%d%H%M%S).log"
	mkdir -p "$SUPERVISOR_DIR/logs"

	# Ensure we're on main and in sync before releasing
	local current_branch
	current_branch=$(git -C "$repo" branch --show-current 2>/dev/null || echo "")
	if [[ "$current_branch" != "main" ]]; then
		log_warn "Repo not on main branch (on: $current_branch), switching..."
		git -C "$repo" checkout main 2>/dev/null || {
			log_error "Failed to switch to main branch for release"
			return 1
		}
	fi

	# t276: Stash any dirty working tree before release.
	# Common cause: todo/VERIFY.md, untracked files from parallel sessions.
	# version-manager.sh refuses to release with uncommitted changes.
	local stashed=false
	if [[ -n "$(git -C "$repo" status --porcelain 2>/dev/null)" ]]; then
		log_info "Stashing dirty working tree before release..."
		if git -C "$repo" stash push -m "auto-release-stash-$(date +%Y%m%d%H%M%S)" 2>/dev/null; then
			stashed=true
		else
			log_warn "git stash failed, proceeding anyway (release may fail)"
		fi
	fi

	# Pull latest (all batch PRs should be merged by now)
	git -C "$repo" pull --ff-only origin main 2>/dev/null || {
		log_warn "Fast-forward pull failed, trying rebase..."
		git -C "$repo" pull --rebase origin main 2>/dev/null || {
			log_error "Failed to pull latest main for release"
			[[ "$stashed" == "true" ]] && git -C "$repo" stash pop 2>/dev/null || true
			return 1
		}
	}

	# Run the release (--skip-preflight: batch tasks already passed CI individually)
	# Use --force to bypass empty CHANGELOG check (auto-generates from commits)
	local release_output=""
	local release_exit=0
	release_output=$(cd "$repo" && bash "$version_manager" release "$release_type" --skip-preflight --force 2>&1) || release_exit=$?

	# t276: Restore stashed changes after release (regardless of success/failure)
	if [[ "$stashed" == "true" ]]; then
		log_info "Restoring stashed working tree..."
		git -C "$repo" stash pop 2>/dev/null || log_warn "git stash pop failed (may need manual recovery)"
	fi

	echo "$release_output" >"$release_log" 2>/dev/null || true

	if [[ "$release_exit" -ne 0 ]]; then
		log_error "Release failed for batch $batch_name (exit: $release_exit)"
		log_error "See log: $release_log"
		# Store failure in memory for future reference
		if [[ -x "$MEMORY_HELPER" ]]; then
			"$MEMORY_HELPER" store \
				--auto \
				--type "FAILED_APPROACH" \
				--content "Batch release failed: $batch_name ($release_type). Exit: $release_exit. Check $release_log" \
				--tags "supervisor,release,batch,$batch_name,failed" \
				2>/dev/null || true
		fi
		# Send notification about release failure
		send_task_notification "batch-$batch_id" "failed" "Batch release ($release_type) failed for $batch_name" 2>/dev/null || true
		return 1
	fi

	# Extract the new version from the release output
	local new_version
	new_version=$(echo "$release_output" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | tail -1 || echo "unknown")

	log_success "Release $new_version created for batch $batch_name ($release_type)"

	# Store success in memory
	if [[ -x "$MEMORY_HELPER" ]]; then
		"$MEMORY_HELPER" store \
			--auto \
			--type "WORKING_SOLUTION" \
			--content "Batch release succeeded: $batch_name -> v$new_version ($release_type). $complete_count/$total_tasks tasks, $failed_count failed." \
			--tags "supervisor,release,batch,$batch_name,success,v$new_version" \
			2>/dev/null || true
	fi

	# Send notification about successful release
	send_task_notification "batch-$batch_id" "deployed" "Released v$new_version ($release_type) for batch $batch_name" 2>/dev/null || true

	# macOS celebration notification
	if [[ "$(uname)" == "Darwin" ]]; then
		nohup afplay /System/Library/Sounds/Hero.aiff &>/dev/null &
	fi

	return 0
}

# Command handler for manual release trigger
cmd_release() {
	local batch_id="" release_type="" enable_flag="" dry_run="false"

	if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
		batch_id="$1"
		shift
	fi

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--type)
			[[ $# -lt 2 ]] && {
				log_error "--type requires a value"
				return 1
			}
			release_type="$2"
			shift 2
			;;
		--enable)
			enable_flag="enable"
			shift
			;;
		--disable)
			enable_flag="disable"
			shift
			;;
		--dry-run)
			dry_run="true"
			shift
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$batch_id" ]]; then
		# Find the most recently completed batch
		ensure_db
		batch_id=$(db "$SUPERVISOR_DB" "
            SELECT id FROM batches WHERE status = 'complete'
            ORDER BY updated_at DESC LIMIT 1;
        " 2>/dev/null || echo "")

		if [[ -z "$batch_id" ]]; then
			log_error "No batch specified and no completed batches found."
			log_error "Usage: supervisor-helper.sh release <batch_id> [--type patch|minor|major] [--enable|--disable] [--dry-run]"
			return 1
		fi
		log_info "Using most recently completed batch: $batch_id"
	fi

	ensure_db

	local escaped_batch
	escaped_batch=$(sql_escape "$batch_id")

	# Look up batch (by ID or name)
	local batch_row
	batch_row=$(db -separator '|' "$SUPERVISOR_DB" "
        SELECT id, name, status, release_on_complete, release_type
        FROM batches WHERE id = '$escaped_batch' OR name = '$escaped_batch'
        LIMIT 1;
    ")

	if [[ -z "$batch_row" ]]; then
		log_error "Batch not found: $batch_id"
		return 1
	fi

	local bid bname bstatus brelease_flag brelease_type
	IFS='|' read -r bid bname bstatus brelease_flag brelease_type <<<"$batch_row"
	escaped_batch=$(sql_escape "$bid")

	# Handle enable/disable mode
	if [[ -n "$enable_flag" ]]; then
		if [[ "$enable_flag" == "enable" ]]; then
			local new_type="${release_type:-${brelease_type:-patch}}"
			db "$SUPERVISOR_DB" "
                UPDATE batches SET release_on_complete = 1, release_type = '$(sql_escape "$new_type")',
                updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
                WHERE id = '$escaped_batch';
            "
			log_success "Enabled release_on_complete for batch $bname (type: $new_type)"
		else
			db "$SUPERVISOR_DB" "
                UPDATE batches SET release_on_complete = 0,
                updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
                WHERE id = '$escaped_batch';
            "
			log_success "Disabled release_on_complete for batch $bname"
		fi
		return 0
	fi

	# Manual release trigger mode
	if [[ -z "$release_type" ]]; then
		release_type="${brelease_type:-patch}"
	fi

	# Validate release_type
	case "$release_type" in
	major | minor | patch) ;;
	*)
		log_error "Invalid release type: $release_type"
		return 1
		;;
	esac

	# Get repo from first task in batch
	local batch_repo
	batch_repo=$(db "$SUPERVISOR_DB" "
        SELECT t.repo FROM batch_tasks bt
        JOIN tasks t ON bt.task_id = t.id
        WHERE bt.batch_id = '$escaped_batch'
        ORDER BY bt.position LIMIT 1;
    " 2>/dev/null || echo "")

	if [[ -z "$batch_repo" ]]; then
		log_error "No tasks found in batch $bname - cannot determine repo"
		return 1
	fi

	echo -e "${BOLD}=== Batch Release: $bname ===${NC}"
	echo "  Batch:   $bid"
	echo "  Status:  $bstatus"
	echo "  Type:    $release_type"
	echo "  Repo:    $batch_repo"

	if [[ "$dry_run" == "true" ]]; then
		log_info "[dry-run] Would trigger $release_type release for batch $bname from $batch_repo"
		return 0
	fi

	trigger_batch_release "$bid" "$release_type" "$batch_repo"
	return $?
}
