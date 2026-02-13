#!/usr/bin/env bash
# claim-task-id.sh - Distributed task ID allocation with collision prevention
# Part of aidevops framework: https://aidevops.sh
#
# Usage:
#   claim-task-id.sh [options]
#
# Options:
#   --title "Task title"       Task title for GitHub/GitLab issue (required)
#   --description "Details"    Task description (optional)
#   --labels "label1,label2"   Comma-separated labels (optional)
#   --offline                  Force offline mode (skip remote issue creation)
#   --dry-run                  Show what would be allocated without creating issue
#   --repo-path PATH           Path to git repository (default: current directory)
#
# Exit codes:
#   0 - Success (outputs: task_id=tNNN ref=GH#NNN or GL#NNN)
#   1 - Error (network failure, git error, etc.)
#   2 - Offline fallback used (outputs: task_id=tNNN+100 ref=offline)
#
# Algorithm:
#   1. Online mode (default):
#      - Create GitHub/GitLab issue first (distributed lock)
#      - Fetch origin/main:TODO.md
#      - Scan for highest tNNN
#      - Allocate t(N+1)
#      - Output: task_id=tNNN ref=GH#NNN
#
#   2. Offline fallback:
#      - Scan local TODO.md for highest tNNN
#      - Allocate t(N+100) to avoid collisions
#      - Output: task_id=tNNN+100 ref=offline
#      - Reconciliation: manual review when back online
#
# Platform detection:
#   - Checks git remote URL for github.com, gitlab.com, gitea
#   - Uses gh CLI for GitHub, glab CLI for GitLab
#   - Falls back to offline if CLI not available

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# Configuration
OFFLINE_MODE=false
DRY_RUN=false
TASK_TITLE=""
TASK_DESCRIPTION=""
TASK_LABELS=""
REPO_PATH="$PWD"
OFFLINE_OFFSET=100

# Logging
log_info() { echo -e "${BLUE}[INFO]${NC} $*" >&2; }
log_success() { echo -e "${GREEN}[OK]${NC} $*" >&2; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

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
		--offline)
			OFFLINE_MODE=true
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

	if [[ -z "$TASK_TITLE" ]]; then
		log_error "Missing required argument: --title"
		exit 1
	fi
}

# Detect git platform from remote URL
detect_platform() {
	local remote_url
	remote_url=$(cd "$REPO_PATH" && git remote get-url origin 2>/dev/null || echo "")

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
		if command -v gh &>/dev/null; then
			return 0
		fi
		;;
	gitlab)
		if command -v glab &>/dev/null; then
			return 0
		fi
		;;
	esac

	return 1
}

# Get highest task ID from TODO.md content
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

# Fetch TODO.md from origin/main
fetch_remote_todo() {
	local repo_path="$1"

	cd "$repo_path" || return 1

	# Fetch latest from origin
	if ! git fetch origin main 2>/dev/null; then
		log_warn "Failed to fetch origin/main"
		return 1
	fi

	# Get TODO.md content from origin/main
	if ! git show origin/main:TODO.md 2>/dev/null; then
		log_warn "Failed to read origin/main:TODO.md"
		return 1
	fi

	return 0
}

# Create GitHub issue
create_github_issue() {
	local title="$1"
	local description="$2"
	local labels="$3"
	local repo_path="$4"

	cd "$repo_path" || return 1

	local gh_args=(issue create --title "$title")

	if [[ -n "$description" ]]; then
		gh_args+=(--body "$description")
	else
		gh_args+=(--body "Task created via claim-task-id.sh")
	fi

	if [[ -n "$labels" ]]; then
		gh_args+=(--label "$labels")
	fi

	# Create issue and extract number from URL
	local issue_url
	if ! issue_url=$(gh "${gh_args[@]}" 2>&1); then
		log_error "Failed to create GitHub issue: $issue_url"
		return 1
	fi

	# Extract issue number from URL (e.g., https://github.com/user/repo/issues/123)
	local issue_num
	issue_num=$(echo "$issue_url" | grep -oE '[0-9]+$')

	if [[ -z "$issue_num" ]]; then
		log_error "Failed to extract issue number from: $issue_url"
		return 1
	fi

	echo "$issue_num"
	return 0
}

# Update GitHub issue title with task ID prefix
update_github_issue_title() {
	local issue_num="$1"
	local task_id="$2"
	local original_title="$3"
	local repo_path="$4"

	cd "$repo_path" || return 1

	local new_title="${task_id}: ${original_title}"

	if ! gh issue edit "$issue_num" --title "$new_title" 2>&1; then
		log_warn "Failed to update GitHub issue #${issue_num} title to: $new_title"
		return 1
	fi

	log_success "Updated GitHub issue #${issue_num} title to: $new_title"
	return 0
}

# Create GitLab issue
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

	# Create issue and extract number
	local issue_output
	if ! issue_output=$(glab "${glab_args[@]}" 2>&1); then
		log_error "Failed to create GitLab issue: $issue_output"
		return 1
	fi

	# Extract issue number (glab outputs: #123 or similar)
	local issue_num
	issue_num=$(echo "$issue_output" | grep -oE '#[0-9]+' | head -1 | tr -d '#')

	if [[ -z "$issue_num" ]]; then
		log_error "Failed to extract issue number from: $issue_output"
		return 1
	fi

	echo "$issue_num"
	return 0
}

# Update GitLab issue title with task ID prefix
update_gitlab_issue_title() {
	local issue_num="$1"
	local task_id="$2"
	local original_title="$3"
	local repo_path="$4"

	cd "$repo_path" || return 1

	local new_title="${task_id}: ${original_title}"

	if ! glab issue update "$issue_num" --title "$new_title" 2>&1; then
		log_warn "Failed to update GitLab issue #${issue_num} title to: $new_title"
		return 1
	fi

	log_success "Updated GitLab issue #${issue_num} title to: $new_title"
	return 0
}

# Online allocation (with remote issue as distributed lock)
allocate_online() {
	local platform="$1"
	local repo_path="$2"

	log_info "Using online mode with platform: $platform"

	# Step 1: Create remote issue first (distributed lock)
	local issue_num
	case "$platform" in
	github)
		if ! issue_num=$(create_github_issue "$TASK_TITLE" "$TASK_DESCRIPTION" "$TASK_LABELS" "$repo_path"); then
			log_error "Failed to create GitHub issue"
			return 1
		fi
		local ref_prefix="GH"
		;;
	gitlab)
		if ! issue_num=$(create_gitlab_issue "$TASK_TITLE" "$TASK_DESCRIPTION" "$TASK_LABELS" "$repo_path"); then
			log_error "Failed to create GitLab issue"
			return 1
		fi
		local ref_prefix="GL"
		;;
	*)
		log_error "Unsupported platform: $platform"
		return 1
		;;
	esac

	log_success "Created issue: ${ref_prefix}#${issue_num}"

	# Step 2: Fetch origin/main:TODO.md
	local todo_content
	if ! todo_content=$(fetch_remote_todo "$repo_path"); then
		log_error "Failed to fetch remote TODO.md"
		return 1
	fi

	# Step 3: Find highest task ID
	local highest_id
	highest_id=$(get_highest_task_id "$todo_content")
	log_info "Highest task ID in origin/main: t${highest_id}"

	# Step 4: Allocate next ID
	local next_id=$((highest_id + 1))
	log_success "Allocated task ID: t${next_id}"

	# Step 5: Update issue title with task ID prefix
	case "$platform" in
	github)
		update_github_issue_title "$issue_num" "t${next_id}" "$TASK_TITLE" "$repo_path" || log_warn "Issue title update failed (non-fatal)"
		;;
	gitlab)
		update_gitlab_issue_title "$issue_num" "t${next_id}" "$TASK_TITLE" "$repo_path" || log_warn "Issue title update failed (non-fatal)"
		;;
	esac

	# Output in machine-readable format
	echo "task_id=t${next_id}"
	echo "ref=${ref_prefix}#${issue_num}"
	echo "issue_url=$(cd "$repo_path" && git remote get-url origin | sed 's/\.git$//')/issues/${issue_num}"

	return 0
}

# Offline allocation (with safety offset)
allocate_offline() {
	local repo_path="$1"

	log_warn "Using offline mode with +${OFFLINE_OFFSET} offset"

	# Read local TODO.md
	local todo_path="${repo_path}/TODO.md"
	if [[ ! -f "$todo_path" ]]; then
		log_error "TODO.md not found at: $todo_path"
		return 1
	fi

	local todo_content
	todo_content=$(cat "$todo_path")

	# Find highest task ID
	local highest_id
	highest_id=$(get_highest_task_id "$todo_content")
	log_info "Highest task ID in local TODO.md: t${highest_id}"

	# Allocate with offset
	local next_id=$((highest_id + OFFLINE_OFFSET))
	log_warn "Allocated task ID with offset: t${next_id}"
	log_warn "Reconciliation required when back online"

	# Output in machine-readable format
	echo "task_id=t${next_id}"
	echo "ref=offline"
	echo "reconcile=true"

	return 2 # Exit code 2 indicates offline fallback
}

# Main execution
main() {
	parse_args "$@"

	if [[ "$DRY_RUN" == "true" ]]; then
		log_info "DRY RUN mode - no changes will be made"
	fi

	# Detect platform
	local platform
	platform=$(detect_platform)
	log_info "Detected platform: $platform"

	# Check if we should use online mode
	if [[ "$OFFLINE_MODE" == "false" ]] && [[ "$platform" != "unknown" ]]; then
		if check_cli "$platform"; then
			if [[ "$DRY_RUN" == "true" ]]; then
				log_info "Would create ${platform} issue and allocate task ID"
				local platform_upper
				platform_upper=$(echo "$platform" | tr '[:lower:]' '[:upper:]')
				echo "task_id=tDRY_RUN"
				echo "ref=${platform_upper}#DRY_RUN"
				return 0
			fi

			if allocate_online "$platform" "$REPO_PATH"; then
				return 0
			else
				log_warn "Online allocation failed, falling back to offline mode"
			fi
		else
			log_warn "CLI tool not available for ${platform}, using offline mode"
		fi
	fi

	# Fallback to offline mode
	if [[ "$DRY_RUN" == "true" ]]; then
		log_info "Would allocate task ID in offline mode"
		echo "task_id=tDRY_RUN+${OFFLINE_OFFSET}"
		echo "ref=offline"
		return 2
	fi

	allocate_offline "$REPO_PATH"
}

main "$@"
