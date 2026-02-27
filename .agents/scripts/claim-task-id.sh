#!/usr/bin/env bash
# claim-task-id.sh - Atomic task ID allocation via .task-counter file
# Part of aidevops framework: https://aidevops.sh
#
# Usage:
#   claim-task-id.sh [options]
#
# Options:
#   --title "Task title"       Task title for GitHub/GitLab issue (required unless --batch)
#   --description "Details"    Task description (optional)
#   --labels "label1,label2"   Comma-separated labels (optional)
#   --count N                  Allocate N consecutive IDs (default: 1)
#                              Creates one GitHub/GitLab issue per ID using
#                              the same --title. Output includes ref_tNNN=GH#NNN
#                              for each created issue.
#   --offline                  Force offline mode (skip remote push)
#   --no-issue                 Skip GitHub/GitLab issue creation
#   --dry-run                  Show what would be allocated without changes
#   --repo-path PATH           Path to git repository (default: current directory)
#   --remote NAME              Git remote name for counter branch (default: origin,
#                              or value from .aidevops.json "remote" key)
#   --counter-branch BRANCH    Branch holding .task-counter (default: main,
#                              or value from .aidevops.json "counter_branch" key)
#
# Project-level config (.aidevops.json in repo root):
#   {
#     "remote": "upstream",
#     "default_branch": "develop",
#     "counter_branch": "develop"
#   }
#   Keys:
#     remote          - git remote name (default: "origin")
#     default_branch  - informational default branch name (not used by CAS)
#     counter_branch  - branch that holds .task-counter (default: "main")
#   CLI flags --remote and --counter-branch override .aidevops.json values.
#
# Exit codes:
#   0 - Success (outputs: task_id=tNNN ref=GH#NNN or GL#NNN)
#   1 - Error (network failure, git error, etc.)
#   2 - Offline fallback used (outputs: task_id=tNNN ref=offline)
#
# Algorithm (CAS loop — compare-and-swap via git push):
#   1. git fetch <remote> <counter_branch>
#   2. Read <remote>/<counter_branch>:.task-counter → current value (e.g. 1048)
#   3. Claim IDs: 1048 to 1048+count-1
#   4. Write 1048+count to .task-counter
#   5. git commit .task-counter && git push <remote> HEAD:<counter_branch>
#   6. If push fails (conflict) → retry from step 1 (max 10 attempts)
#   7. On success, create GitHub/GitLab issue per ID (optional, non-blocking)
#
# The .task-counter file is the single source of truth for the next
# available task ID. It contains one integer. Every allocation atomically
# increments it via a git push, which fails on conflict — guaranteeing
# no two sessions can claim the same ID.
#
# Offline fallback:
#   - Reads local .task-counter + 100 offset to avoid collisions
#   - Reconciliation required when back online
#
# Migration from TODO.md scanning:
#   - If .task-counter doesn't exist, initialize from TODO.md highest ID
#   - First run creates .task-counter and commits to <remote>/<counter_branch>
#
# Platform detection:
#   - Checks git remote URL for github.com, gitlab.com, gitea
#   - Uses gh CLI for GitHub, glab CLI for GitLab
#   - Falls back to --no-issue if CLI not available

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# Configuration
OFFLINE_MODE=false
DRY_RUN=false
NO_ISSUE=false
TASK_TITLE=""
TASK_DESCRIPTION=""
TASK_LABELS=""
REPO_PATH="$PWD"
ALLOC_COUNT=1
OFFLINE_OFFSET=100
CAS_MAX_RETRIES=10
COUNTER_FILE=".task-counter"
# Remote and branch — defaults; overridden by .aidevops.json and/or CLI flags
REMOTE_NAME="origin"
COUNTER_BRANCH="main"
# Track whether CLI flags explicitly set these (CLI overrides config file)
_REMOTE_NAME_SET=false
_COUNTER_BRANCH_SET=false

# Logging (all to stderr so stdout is machine-readable)
# Logging: uses shared log_* from shared-constants.sh

# Load project-level config from .aidevops.json in the repo root.
# Populates REMOTE_NAME and COUNTER_BRANCH unless already set by CLI flags.
# Requires: jq (optional — silently skipped if not installed).
load_project_config() {
	local repo_path="$1"
	local config_file="${repo_path}/.aidevops.json"

	if [[ ! -f "$config_file" ]]; then
		return 0
	fi

	if ! command -v jq &>/dev/null; then
		log_warn ".aidevops.json found but jq is not installed — project config ignored"
		return 0
	fi

	log_info "Loading project config from .aidevops.json"

	local remote_val counter_branch_val
	remote_val=$(jq -r '.remote // empty' "$config_file" 2>/dev/null || true)
	counter_branch_val=$(jq -r '.counter_branch // empty' "$config_file" 2>/dev/null || true)

	# CLI flags take precedence over config file
	if [[ -n "$remote_val" ]] && [[ "$_REMOTE_NAME_SET" == "false" ]]; then
		REMOTE_NAME="$remote_val"
		log_info "remote set from .aidevops.json: $REMOTE_NAME"
	fi

	if [[ -n "$counter_branch_val" ]] && [[ "$_COUNTER_BRANCH_SET" == "false" ]]; then
		COUNTER_BRANCH="$counter_branch_val"
		log_info "counter_branch set from .aidevops.json: $COUNTER_BRANCH"
	fi

	return 0
}

# Extract hashtags from text and convert to comma-separated labels
extract_hashtags() {
	local text="$1"
	local tags=""

	while [[ "$text" =~ \#([a-zA-Z0-9_-]+) ]]; do
		local tag="${BASH_REMATCH[1]}"
		if [[ -n "$tags" ]]; then
			tags="${tags},${tag}"
		else
			tags="$tag"
		fi
		text="${text#*#"${tag}"}"
	done

	echo "$tags"
}

# Parse arguments
parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--title)
			TASK_TITLE="$2"
			shift 2
			;;
		--description)
			TASK_DESCRIPTION="$2"
			shift 2
			;;
		--labels)
			TASK_LABELS="$2"
			shift 2
			;;
		--count)
			ALLOC_COUNT="$2"
			if ! [[ "$ALLOC_COUNT" =~ ^[0-9]+$ ]] || [[ "$ALLOC_COUNT" -lt 1 ]]; then
				log_error "--count must be a positive integer"
				exit 1
			fi
			shift 2
			;;
		--offline)
			OFFLINE_MODE=true
			shift
			;;
		--no-issue)
			NO_ISSUE=true
			shift
			;;
		--dry-run)
			DRY_RUN=true
			shift
			;;
		--repo-path)
			REPO_PATH="$2"
			shift 2
			;;
		--remote)
			REMOTE_NAME="$2"
			_REMOTE_NAME_SET=true
			shift 2
			;;
		--counter-branch)
			COUNTER_BRANCH="$2"
			_COUNTER_BRANCH_SET=true
			shift 2
			;;
		--help)
			grep '^#' "$0" | grep -v '#!/usr/bin/env' | sed 's/^# //' | sed 's/^#//'
			exit 0
			;;
		*)
			log_error "Unknown option: $1"
			exit 1
			;;
		esac
	done

	# Validate batch size
	if [[ "$ALLOC_COUNT" -lt 1 ]]; then
		log_error "Allocation count must be >= 1"
		exit 1
	fi

	# Title is required unless batch mode
	if [[ -z "$TASK_TITLE" ]] && [[ "$ALLOC_COUNT" -eq 1 ]]; then
		log_error "Missing required argument: --title (or use --count N for bulk allocation)"
		exit 1
	fi

	# Auto-extract hashtags from title if no labels provided
	if [[ -n "$TASK_TITLE" ]] && [[ -z "$TASK_LABELS" ]]; then
		local extracted_tags
		extracted_tags=$(extract_hashtags "$TASK_TITLE")
		if [[ -n "$extracted_tags" ]]; then
			TASK_LABELS="$extracted_tags"
			log_info "Auto-extracted labels from title: $TASK_LABELS"
		fi
	fi
}

# Detect git platform from remote URL
detect_platform() {
	local remote_url
	remote_url=$(cd "$REPO_PATH" && git remote get-url "$REMOTE_NAME" 2>/dev/null || echo "")

	if [[ -z "$remote_url" ]]; then
		echo "unknown"
		return
	fi

	if [[ "$remote_url" =~ github\.com ]]; then
		echo "github"
	elif [[ "$remote_url" =~ gitlab\.com ]]; then
		echo "gitlab"
	elif [[ "$remote_url" =~ gitea ]]; then
		echo "gitea"
	else
		echo "unknown"
	fi
}

# Check if CLI tool is available
check_cli() {
	local platform="$1"

	case "$platform" in
	github)
		command -v gh &>/dev/null && return 0
		;;
	gitlab)
		command -v glab &>/dev/null && return 0
		;;
	esac

	return 1
}

# Get highest task ID from TODO.md content (used for migration only)
get_highest_task_id() {
	local todo_content="$1"
	local highest=0

	# Extract all task IDs (tNNN or tNNN.N format)
	while IFS= read -r line; do
		if [[ "$line" =~ ^[[:space:]]*-[[:space:]]\[[[:space:]xX]\][[:space:]]t([0-9]+) ]]; then
			local task_num="${BASH_REMATCH[1]}"
			if ((10#$task_num > 10#$highest)); then
				highest="$task_num"
			fi
		fi
	done <<<"$todo_content"

	echo "$highest"
}

# Read .task-counter from <remote>/<counter_branch> (fetches first)
read_remote_counter() {
	local repo_path="$1"

	cd "$repo_path" || return 1

	if ! git fetch "$REMOTE_NAME" "$COUNTER_BRANCH" 2>/dev/null; then
		log_warn "Failed to fetch ${REMOTE_NAME}/${COUNTER_BRANCH}"
		return 1
	fi

	local counter_value
	counter_value=$(git show "${REMOTE_NAME}/${COUNTER_BRANCH}:${COUNTER_FILE}" 2>/dev/null | tr -d '[:space:]')

	if [[ -z "$counter_value" ]] || ! [[ "$counter_value" =~ ^[0-9]+$ ]]; then
		log_warn "Invalid or missing ${COUNTER_FILE} on ${REMOTE_NAME}/${COUNTER_BRANCH}"
		return 1
	fi

	echo "$counter_value"
	return 0
}

# Read .task-counter from local working tree
read_local_counter() {
	local repo_path="$1"
	local counter_path="${repo_path}/${COUNTER_FILE}"

	if [[ ! -f "$counter_path" ]]; then
		log_warn "${COUNTER_FILE} not found at: $counter_path"
		return 1
	fi

	local counter_value
	counter_value=$(tr -d '[:space:]' <"$counter_path")

	if [[ -z "$counter_value" ]] || ! [[ "$counter_value" =~ ^[0-9]+$ ]]; then
		log_warn "Invalid ${COUNTER_FILE} content: $counter_value"
		return 1
	fi

	echo "$counter_value"
	return 0
}

# Atomic CAS allocation: fetch → read → increment → commit → push
# Returns 0 on success, 1 on hard error, 2 on retriable conflict
allocate_counter_cas() {
	local repo_path="$1"
	local count="$2"

	cd "$repo_path" || return 1

	# Step 1: Read current counter from <remote>/<counter_branch>
	local current_value
	if ! current_value=$(read_remote_counter "$repo_path"); then
		return 1
	fi

	local first_id="$current_value"
	local last_id=$((current_value + count - 1))
	local new_counter=$((current_value + count))

	log_info "Counter at ${current_value}, claiming t${first_id}..t${last_id}, new counter: ${new_counter}"

	# Step 2: Build a commit directly on <remote>/<counter_branch> using plumbing commands.
	# This is safe from any branch — we never touch HEAD or the working tree index.
	cd "$repo_path" || return 1

	local commit_msg="chore: claim task ID"
	if [[ "$count" -eq 1 ]]; then
		commit_msg="chore: claim t${first_id}"
	else
		commit_msg="chore: claim t${first_id}..t${last_id}"
	fi

	# Create a blob with the new counter value
	local blob_sha
	blob_sha=$(echo "$new_counter" | git hash-object -w --stdin 2>/dev/null) || {
		log_warn "Failed to create blob"
		return 1
	}

	# Read <remote>/<counter_branch>'s tree, replace .task-counter with our new blob
	local tree_sha
	tree_sha=$(git ls-tree "${REMOTE_NAME}/${COUNTER_BRANCH}" | sed "s|[0-9a-f]\{40,64\}	${COUNTER_FILE}$|${blob_sha}	${COUNTER_FILE}|" | git mktree 2>/dev/null) || {
		log_warn "Failed to create tree"
		return 1
	}

	# Create a commit on top of <remote>/<counter_branch>
	local parent_sha
	parent_sha=$(git rev-parse "${REMOTE_NAME}/${COUNTER_BRANCH}" 2>/dev/null) || {
		log_warn "Failed to resolve ${REMOTE_NAME}/${COUNTER_BRANCH}"
		return 1
	}

	local commit_sha
	commit_sha=$(git commit-tree "$tree_sha" -p "$parent_sha" -m "$commit_msg" 2>/dev/null) || {
		log_warn "Failed to create commit"
		return 1
	}

	# Step 3: Push the exact commit to <counter_branch> — this is the atomic gate.
	# If another session pushed between our fetch and now, this fails (non-fast-forward).
	# Safe from any branch: we push a specific SHA, not HEAD.
	if ! git push "$REMOTE_NAME" "${commit_sha}:refs/heads/${COUNTER_BRANCH}" 2>/dev/null; then
		log_warn "Push failed (conflict — another session claimed an ID)"
		# Fetch latest for next retry attempt
		git fetch "$REMOTE_NAME" "$COUNTER_BRANCH" 2>/dev/null || true
		return 2
	fi

	# Update local ref so subsequent fetches see our commit
	git fetch "$REMOTE_NAME" "$COUNTER_BRANCH" 2>/dev/null || true

	# Success — output the claimed IDs
	echo "$first_id"
	return 0
}

# Online allocation with CAS retry loop
allocate_online() {
	local repo_path="$1"
	local count="$2"
	local attempt=0
	local first_id=""

	while [[ $attempt -lt $CAS_MAX_RETRIES ]]; do
		attempt=$((attempt + 1))

		if [[ $attempt -gt 1 ]]; then
			log_info "Retry attempt ${attempt}/${CAS_MAX_RETRIES}..."
			# Brief backoff: 0.1s * attempt, capped at 1.0s, plus jitter to avoid thundering herd
			local capped=$((attempt > 10 ? 10 : attempt))
			local jitter_ms=$((RANDOM % 300))
			local backoff
			backoff=$(awk "BEGIN {printf \"%.1f\", $capped * 0.1 + $jitter_ms / 1000}")
			sleep "$backoff" 2>/dev/null || true
		fi

		local cas_result=0
		first_id=$(allocate_counter_cas "$repo_path" "$count") || cas_result=$?

		case $cas_result in
		0)
			log_success "Claimed t${first_id} (attempt ${attempt})"
			echo "$first_id"
			return 0
			;;
		2)
			# Retriable conflict — loop continues
			continue
			;;
		*)
			log_error "Hard error during allocation"
			return 1
			;;
		esac
	done

	log_error "Failed to allocate after ${CAS_MAX_RETRIES} attempts"
	return 1
}

# Offline allocation (with safety offset)
allocate_offline() {
	local repo_path="$1"
	local count="$2"

	log_warn "Using offline mode with +${OFFLINE_OFFSET} offset"

	local current_value
	if ! current_value=$(read_local_counter "$repo_path"); then
		log_error "Cannot read local ${COUNTER_FILE}"
		return 1
	fi

	local first_id=$((current_value + OFFLINE_OFFSET))
	local last_id=$((first_id + count - 1))
	local new_counter=$((first_id + count))

	# Update local counter (no push)
	echo "$new_counter" >"${repo_path}/${COUNTER_FILE}"

	log_warn "Allocated t${first_id} with offset (reconcile when back online)"

	echo "$first_id"
	return 0
}

# Create GitHub issue (post-allocation, non-blocking)
# t1324: Delegates to issue-sync-helper.sh push when available for rich
# issue bodies, proper labels (including auto-dispatch), and duplicate
# detection. Falls back to bare gh issue create if helper not found.
create_github_issue() {
	local title="$1"
	local description="$2"
	local labels="$3"
	local repo_path="$4"

	cd "$repo_path" || return 1

	# Extract task ID from title (format: "tNNN: description")
	local task_id
	task_id=$(printf '%s' "$title" | grep -oE '^t[0-9]+' || echo "")

	# t1324: Delegate to issue-sync-helper.sh for rich issue creation
	# This ensures proper labels, body composition, and duplicate detection
	local issue_sync_helper="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/issue-sync-helper.sh"
	if [[ -n "$task_id" && -x "$issue_sync_helper" && -f "$repo_path/TODO.md" ]]; then
		local push_output
		push_output=$("$issue_sync_helper" push "$task_id" 2>/dev/null || echo "")

		local issue_num
		issue_num=$(printf '%s' "$push_output" | grep -oE 'Created #[0-9]+' | grep -oE '[0-9]+' | head -1 || echo "")

		# Also check if it found an existing issue (already has ref)
		if [[ -z "$issue_num" ]]; then
			issue_num=$(printf '%s' "$push_output" | grep -oE 'already has issue #[0-9]+' | grep -oE '[0-9]+' | head -1 || echo "")
		fi

		if [[ -n "$issue_num" ]]; then
			log_info "Issue created via issue-sync-helper.sh: #$issue_num"
			echo "$issue_num"
			return 0
		fi
		log_warn "issue-sync-helper.sh push returned no issue number, falling back to bare creation"
	fi

	# Fallback: bare issue creation (no labels, minimal body)
	local gh_args=(issue create --title "$title")

	if [[ -n "$description" ]]; then
		gh_args+=(--body "$description")
	else
		gh_args+=(--body "Task created via claim-task-id.sh")
	fi

	if [[ -n "$labels" ]]; then
		gh_args+=(--label "$labels")
	fi

	local issue_url
	if ! issue_url=$(gh "${gh_args[@]}" 2>&1); then
		log_warn "Failed to create GitHub issue: $issue_url"
		return 1
	fi

	local issue_num
	issue_num=$(echo "$issue_url" | grep -oE '[0-9]+$')

	if [[ -z "$issue_num" ]]; then
		log_warn "Failed to extract issue number from: $issue_url"
		return 1
	fi

	echo "$issue_num"
	return 0
}

# Create GitLab issue (post-allocation, non-blocking)
create_gitlab_issue() {
	local title="$1"
	local description="$2"
	local labels="$3"
	local repo_path="$4"

	cd "$repo_path" || return 1

	local glab_args=(issue create --title "$title")

	if [[ -n "$description" ]]; then
		glab_args+=(--description "$description")
	else
		glab_args+=(--description "Task created via claim-task-id.sh")
	fi

	if [[ -n "$labels" ]]; then
		glab_args+=(--label "$labels")
	fi

	local issue_output
	if ! issue_output=$(glab "${glab_args[@]}" 2>&1); then
		log_warn "Failed to create GitLab issue: $issue_output"
		return 1
	fi

	local issue_num
	issue_num=$(echo "$issue_output" | grep -oE '#[0-9]+' | head -1 | tr -d '#')

	if [[ -z "$issue_num" ]]; then
		log_warn "Failed to extract issue number from: $issue_output"
		return 1
	fi

	echo "$issue_num"
	return 0
}

# Main execution
main() {
	parse_args "$@"

	# Load project config after parse_args so REPO_PATH is resolved,
	# but before detect_platform so REMOTE_NAME is set correctly.
	load_project_config "$REPO_PATH"

	if [[ "$DRY_RUN" == "true" ]]; then
		log_info "DRY RUN mode - no changes will be made"
	fi

	log_info "Using remote: ${REMOTE_NAME}, counter branch: ${COUNTER_BRANCH}"

	local platform
	platform=$(detect_platform)
	log_info "Detected platform: $platform"

	# --- Allocate the ID(s) first (the critical atomic step) ---

	local first_id=""
	local is_offline="false"

	if [[ "$OFFLINE_MODE" == "false" ]]; then
		if [[ "$DRY_RUN" == "true" ]]; then
			local current
			current=$(read_remote_counter "$REPO_PATH" 2>/dev/null || read_local_counter "$REPO_PATH" 2>/dev/null || echo "?")
			if [[ "$current" =~ ^[0-9]+$ ]]; then
				log_info "Would allocate t${current}..t$((current + ALLOC_COUNT - 1)) (counter at ${current})"
			else
				log_info "Would allocate task ID (counter unreadable: ${current})"
			fi
			echo "task_id=tDRY_RUN"
			echo "ref=DRY_RUN"
			return 0
		fi

		if first_id=$(allocate_online "$REPO_PATH" "$ALLOC_COUNT"); then
			log_success "Allocated task ID: t${first_id}"
		else
			log_warn "Online allocation failed, falling back to offline mode"
			is_offline="true"
		fi
	else
		is_offline="true"
	fi

	if [[ "$is_offline" == "true" ]]; then
		if [[ "$DRY_RUN" == "true" ]]; then
			log_info "Would allocate task ID in offline mode"
			echo "task_id=tDRY_RUN"
			echo "ref=offline"
			return 2
		fi

		if ! first_id=$(allocate_offline "$REPO_PATH" "$ALLOC_COUNT"); then
			log_error "Offline allocation failed"
			return 1
		fi
	fi

	# --- Create issues AFTER IDs are secured (optional, non-blocking) ---
	# For batch allocations (--count N), create one issue per allocated ID.

	local ref_prefix=""
	local last_id=$((first_id + ALLOC_COUNT - 1))
	# Associative-style parallel arrays: issue_nums[0..N-1] for each allocated ID
	local -a issue_nums=()
	local has_any_issue=false

	if [[ "$NO_ISSUE" == "false" ]] && [[ "$is_offline" == "false" ]] && [[ "$platform" != "unknown" ]]; then
		if check_cli "$platform"; then
			case "$platform" in
			github) ref_prefix="GH" ;;
			gitlab) ref_prefix="GL" ;;
			esac

			local i
			for ((i = first_id; i <= last_id; i++)); do
				local issue_title="t${i}: ${TASK_TITLE}"
				local issue_num=""

				case "$platform" in
				github)
					issue_num=$(create_github_issue "$issue_title" "$TASK_DESCRIPTION" "$TASK_LABELS" "$REPO_PATH") || true
					;;
				gitlab)
					issue_num=$(create_gitlab_issue "$issue_title" "$TASK_DESCRIPTION" "$TASK_LABELS" "$REPO_PATH") || true
					;;
				esac

				if [[ -n "$issue_num" ]]; then
					log_success "Created issue: ${ref_prefix}#${issue_num}"
					issue_nums+=("$issue_num")
					has_any_issue=true
				else
					log_warn "Issue creation failed for t${i} (non-fatal — ID is secured)"
					issue_nums+=("")
				fi
			done
		else
			log_warn "CLI for $platform not found — skipping issue creation"
		fi
	fi

	# --- Output machine-readable results ---

	if [[ "$ALLOC_COUNT" -eq 1 ]]; then
		echo "task_id=t${first_id}"
	else
		echo "task_id=t${first_id}"
		echo "task_id_last=t${last_id}"
		echo "task_count=${ALLOC_COUNT}"
	fi

	if [[ "$has_any_issue" == "true" ]]; then
		# Output ref for first issue (primary — backwards compatible)
		echo "ref=${ref_prefix}#${issue_nums[0]}"
		local remote_url
		remote_url=$(cd "$REPO_PATH" && git remote get-url "$REMOTE_NAME" 2>/dev/null | sed 's/\.git$//' || echo "")
		if [[ -n "$remote_url" ]] && [[ -n "${issue_nums[0]}" ]]; then
			echo "issue_url=${remote_url}/issues/${issue_nums[0]}"
		fi
		# Output refs for all issues in batch (new — for callers that parse all output)
		if [[ "$ALLOC_COUNT" -gt 1 ]]; then
			local j
			for ((j = 0; j < ALLOC_COUNT; j++)); do
				local tid=$((first_id + j))
				if [[ -n "${issue_nums[$j]}" ]]; then
					echo "ref_t${tid}=${ref_prefix}#${issue_nums[$j]}"
				fi
			done
		fi
	elif [[ "$is_offline" == "true" ]]; then
		echo "ref=offline"
		echo "reconcile=true"
	else
		echo "ref=none"
	fi

	if [[ "$is_offline" == "true" ]]; then
		return 2
	fi

	return 0
}

main "$@"
