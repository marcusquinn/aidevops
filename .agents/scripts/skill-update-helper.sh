#!/usr/bin/env bash
# =============================================================================
# Skill Update Helper
# =============================================================================
# Check imported skills for upstream updates and optionally auto-update.
# Designed to be run periodically (e.g., weekly cron) or on-demand.
#
# Usage:
#   skill-update-helper.sh check           # Check for updates (default)
#   skill-update-helper.sh update [name]   # Update specific or all skills
#   skill-update-helper.sh status          # Show skill status summary
#   skill-update-helper.sh pr [name]       # Create PRs for updated skills
#
# Options:
#   --auto-update    Automatically update skills with changes
#   --quiet          Suppress non-essential output
#   --json           Output in JSON format
#   --dry-run        Show what would be done without making changes
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# Configuration
AGENTS_DIR="${AIDEVOPS_AGENTS_DIR:-$HOME/.aidevops/agents}"
SKILL_SOURCES="${AGENTS_DIR}/configs/skill-sources.json"
ADD_SKILL_HELPER="${AGENTS_DIR}/scripts/add-skill-helper.sh"

# Options
AUTO_UPDATE=false
QUIET=false
JSON_OUTPUT=false
DRY_RUN=false

# Worktree helper
WORKTREE_HELPER="${SCRIPT_DIR}/worktree-helper.sh"

# =============================================================================
# Helper Functions
# =============================================================================

log_info() {
	if [[ "$QUIET" != true ]]; then
		echo -e "${BLUE}[skill-update]${NC} $1"
	fi
	return 0
}

log_success() {
	if [[ "$QUIET" != true ]]; then
		echo -e "${GREEN}[OK]${NC} $1"
	fi
	return 0
}

log_warning() {
	echo -e "${YELLOW}[WARN]${NC} $1"
	return 0
}

log_error() {
	echo -e "${RED}[ERROR]${NC} $1"
	return 0
}

show_help() {
	cat <<'EOF'
Skill Update Helper - Check and update imported skills

USAGE:
    skill-update-helper.sh <command> [options]

COMMANDS:
    check              Check all skills for upstream updates (default)
    update [name]      Update specific skill or all if no name given
    status             Show summary of all imported skills
    pr [name]          Create PRs for skills with upstream updates

OPTIONS:
    --auto-update      Automatically update skills with changes
    --quiet            Suppress non-essential output
    --json             Output results in JSON format
    --dry-run          Show what would be done without making changes

EXAMPLES:
    # Check for updates
    skill-update-helper.sh check

    # Check and auto-update
    skill-update-helper.sh check --auto-update

    # Update specific skill
    skill-update-helper.sh update cloudflare

    # Update all skills
    skill-update-helper.sh update

    # Get status in JSON (for scripting)
    skill-update-helper.sh status --json

    # Create PRs for all skills with updates
    skill-update-helper.sh pr

    # Create PR for a specific skill
    skill-update-helper.sh pr cloudflare

    # Preview what PRs would be created
    skill-update-helper.sh pr --dry-run

CRON EXAMPLE:
    # Weekly update check (Sundays at 3am)
    0 3 * * 0 ~/.aidevops/agents/scripts/skill-update-helper.sh check --quiet
EOF
	return 0
}

# Check if jq is available
require_jq() {
	if ! command -v jq &>/dev/null; then
		log_error "jq is required for this operation"
		log_info "Install with: brew install jq (macOS) or apt install jq (Ubuntu)"
		exit 1
	fi
	return 0
}

# Check if skill-sources.json exists and has skills
check_skill_sources() {
	if [[ ! -f "$SKILL_SOURCES" ]]; then
		log_info "No skill-sources.json found. No imported skills to check."
		exit 0
	fi

	local count
	count=$(jq '.skills | length' "$SKILL_SOURCES" 2>/dev/null || echo "0")

	if [[ "$count" -eq 0 ]]; then
		log_info "No imported skills found."
		exit 0
	fi

	echo "$count"
	return 0
}

# Parse GitHub URL to extract owner/repo
parse_github_url() {
	local url="$1"

	# Remove https://github.com/ prefix
	url="${url#https://github.com/}"
	url="${url#http://github.com/}"
	url="${url#github.com/}"

	# Remove .git suffix
	url="${url%.git}"

	# Remove /tree/... suffix
	url=$(echo "$url" | sed -E 's|/tree/[^/]+(/.*)?$|\1|')

	echo "$url"
	return 0
}

# Get latest commit from GitHub API
get_latest_commit() {
	local owner_repo="$1"

	local api_url="https://api.github.com/repos/$owner_repo/commits?per_page=1"
	local response

	response=$(curl -s --connect-timeout 10 --max-time 30 \
		-H "Accept: application/vnd.github.v3+json" "$api_url" 2>/dev/null)

	if [[ -z "$response" ]]; then
		return 1
	fi

	local commit
	commit=$(echo "$response" | jq -r '.[0].sha // empty' 2>/dev/null)

	if [[ -z "$commit" || "$commit" == "null" ]]; then
		return 1
	fi

	echo "$commit"
	return 0
}

# Update last_checked timestamp
update_last_checked() {
	local skill_name="$1"
	local timestamp
	timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

	local tmp_file
	tmp_file=$(mktemp)
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "rm -f '${tmp_file}'"

	jq --arg name "$skill_name" --arg ts "$timestamp" \
		'.skills = [.skills[] | if .name == $name then .last_checked = $ts else . end]' \
		"$SKILL_SOURCES" >"$tmp_file" && mv "$tmp_file" "$SKILL_SOURCES"
	return 0
}

# =============================================================================
# Commands
# =============================================================================

cmd_check() {
	require_jq

	local skill_count
	skill_count=$(check_skill_sources)

	log_info "Checking $skill_count imported skill(s) for updates..."
	echo ""

	local updates_available=0
	local up_to_date=0
	local check_failed=0
	local results=()

	# Read skills from JSON
	while IFS= read -r skill_json; do
		local name upstream_url current_commit
		name=$(echo "$skill_json" | jq -r '.name')
		upstream_url=$(echo "$skill_json" | jq -r '.upstream_url')
		current_commit=$(echo "$skill_json" | jq -r '.upstream_commit // empty')

		# Parse owner/repo from URL
		local owner_repo
		owner_repo=$(parse_github_url "$upstream_url")

		# Extract just owner/repo (first two path components)
		owner_repo=$(echo "$owner_repo" | cut -d'/' -f1-2)

		if [[ -z "$owner_repo" || "$owner_repo" == "/" ]]; then
			log_warning "Could not parse URL for $name: $upstream_url"
			((check_failed++)) || true
			continue
		fi

		# Get latest commit
		local latest_commit
		if ! latest_commit=$(get_latest_commit "$owner_repo"); then
			log_warning "Could not fetch latest commit for $name ($owner_repo)"
			((check_failed++)) || true
			continue
		fi

		# Update last_checked timestamp
		update_last_checked "$name"

		# Compare commits
		if [[ -z "$current_commit" ]]; then
			# No commit recorded, consider as update available
			echo -e "${YELLOW}UNKNOWN${NC}: $name (no commit recorded)"
			echo "  Source: $upstream_url"
			echo "  Latest: ${latest_commit:0:7}"
			echo ""
			((updates_available++)) || true
			results+=("{\"name\":\"$name\",\"status\":\"unknown\",\"latest\":\"$latest_commit\"}")
		elif [[ "$latest_commit" != "$current_commit" ]]; then
			echo -e "${YELLOW}UPDATE AVAILABLE${NC}: $name"
			echo "  Current: ${current_commit:0:7}"
			echo "  Latest:  ${latest_commit:0:7}"
			echo "  Run: aidevops skill update $name"
			echo ""
			((updates_available++)) || true
			results+=("{\"name\":\"$name\",\"status\":\"update_available\",\"current\":\"$current_commit\",\"latest\":\"$latest_commit\"}")

			# Auto-update if enabled
			if [[ "$AUTO_UPDATE" == true ]]; then
				log_info "Auto-updating $name..."
				if "$ADD_SKILL_HELPER" add "$upstream_url" --force; then
					log_success "Updated $name"
				else
					log_error "Failed to update $name"
				fi
			fi
		else
			echo -e "${GREEN}Up to date${NC}: $name"
			((up_to_date++)) || true
			results+=("{\"name\":\"$name\",\"status\":\"up_to_date\",\"commit\":\"$current_commit\"}")
		fi

	done < <(jq -c '.skills[]' "$SKILL_SOURCES")

	# Summary
	echo ""
	echo "Summary:"
	echo "  Up to date: $up_to_date"
	echo "  Updates available: $updates_available"
	if [[ $check_failed -gt 0 ]]; then
		echo "  Check failed: $check_failed"
	fi

	# JSON output if requested
	if [[ "$JSON_OUTPUT" == true ]]; then
		echo ""
		echo "{"
		echo "  \"up_to_date\": $up_to_date,"
		echo "  \"updates_available\": $updates_available,"
		echo "  \"check_failed\": $check_failed,"
		# Join results array with comma using printf
		local results_json
		results_json=$(printf '%s,' "${results[@]}")
		results_json="${results_json%,}" # Remove trailing comma
		echo "  \"results\": [$results_json]"
		echo "}"
	fi

	# Return non-zero if updates available (useful for CI)
	if [[ $updates_available -gt 0 ]]; then
		return 1
	fi

	return 0
}

cmd_update() {
	local skill_name="${1:-}"

	require_jq
	check_skill_sources >/dev/null

	if [[ -n "$skill_name" ]]; then
		# Update specific skill
		local upstream_url
		upstream_url=$(jq -r --arg name "$skill_name" '.skills[] | select(.name == $name) | .upstream_url' "$SKILL_SOURCES")

		if [[ -z "$upstream_url" ]]; then
			log_error "Skill not found: $skill_name"
			return 1
		fi

		log_info "Updating $skill_name from $upstream_url"
		"$ADD_SKILL_HELPER" add "$upstream_url" --force
	else
		# Update all skills with available updates
		log_info "Checking and updating all skills..."
		AUTO_UPDATE=true
		# cmd_check returns 1 when updates are available, which is expected here
		cmd_check || true
	fi

	return 0
}

cmd_status() {
	require_jq

	local skill_count
	skill_count=$(check_skill_sources)

	if [[ "$JSON_OUTPUT" == true ]]; then
		jq '{
            total: (.skills | length),
            skills: [.skills[] | {
                name: .name,
                upstream: .upstream_url,
                local_path: .local_path,
                format: .format_detected,
                imported: .imported_at,
                last_checked: .last_checked,
                strategy: .merge_strategy
            }]
        }' "$SKILL_SOURCES"
		return 0
	fi

	echo ""
	echo "Imported Skills Status"
	echo "======================"
	echo ""
	echo "Total: $skill_count skill(s)"
	echo ""

	jq -r '.skills[] | "  \(.name)\n    Path: \(.local_path)\n    Source: \(.upstream_url)\n    Format: \(.format_detected)\n    Imported: \(.imported_at)\n    Last checked: \(.last_checked // "never")\n    Strategy: \(.merge_strategy)\n"' "$SKILL_SOURCES"

	return 0
}

# =============================================================================
# PR Pipeline — create worktree + PR per updated skill (t1082)
# =============================================================================

# Get the repo root (must be run from within the aidevops repo)
get_repo_root() {
	git rev-parse --show-toplevel 2>/dev/null || echo ""
	return 0
}

# Get the default branch (main or master)
get_default_branch() {
	local default_branch
	default_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
	if [[ -n "$default_branch" ]]; then
		echo "$default_branch"
		return 0
	fi
	if git show-ref --verify --quiet refs/heads/main 2>/dev/null; then
		echo "main"
	elif git show-ref --verify --quiet refs/heads/master 2>/dev/null; then
		echo "master"
	else
		echo "main"
	fi
	return 0
}

# Process a single skill update: worktree -> re-import -> commit -> PR
# Arguments:
#   $1 - skill name
#   $2 - upstream URL
#   $3 - current commit (for PR body context)
#   $4 - latest commit
# Returns: 0 on success, 1 on failure
cmd_pr_single() {
	local skill_name="$1"
	local upstream_url="$2"
	local current_commit="$3"
	local latest_commit="$4"

	local repo_root
	repo_root=$(get_repo_root)
	if [[ -z "$repo_root" ]]; then
		log_error "Not in a git repository"
		return 1
	fi

	local default_branch
	default_branch=$(get_default_branch)

	# Branch name: chore/skill-update-<name>
	local branch_name="chore/skill-update-${skill_name}"
	local timestamp
	timestamp=$(date -u +"%Y%m%d")

	# Check if a PR already exists for this branch
	if command -v gh &>/dev/null; then
		local existing_pr
		existing_pr=$(gh pr list --head "$branch_name" --state open --json number --jq '.[0].number' 2>/dev/null || echo "")
		if [[ -n "$existing_pr" ]]; then
			log_warning "PR #${existing_pr} already open for $skill_name — skipping"
			return 0
		fi
	fi

	if [[ "$DRY_RUN" == true ]]; then
		log_info "DRY RUN: Would create PR for $skill_name"
		echo "  Branch: $branch_name"
		echo "  Current: ${current_commit:0:7}"
		echo "  Latest:  ${latest_commit:0:7}"
		echo "  Source:  $upstream_url"
		echo ""
		return 0
	fi

	log_info "Creating PR for skill update: $skill_name"

	# Create worktree using worktree-helper.sh if available, else direct git
	local worktree_path
	if [[ -x "$WORKTREE_HELPER" ]]; then
		# worktree-helper.sh add creates the worktree and prints the path
		local wt_output
		wt_output=$("$WORKTREE_HELPER" add "$branch_name" 2>&1) || {
			# If worktree already exists, extract its path
			if echo "$wt_output" | grep -q "already exists"; then
				worktree_path=$(echo "$wt_output" | grep -oE '/[^ ]+' | head -1)
				log_info "Using existing worktree: $worktree_path"
			else
				log_error "Failed to create worktree for $skill_name: $wt_output"
				return 1
			fi
		}
		# Extract path from output (format: "Path: /path/to/worktree")
		if [[ -z "${worktree_path:-}" ]]; then
			worktree_path=$(echo "$wt_output" | grep "^Path:" | sed 's/^Path: *//' | head -1)
			# Strip ANSI codes if present
			worktree_path=$(echo "$worktree_path" | sed 's/\x1b\[[0-9;]*m//g')
		fi
	fi

	# Fallback: create worktree directly
	if [[ -z "${worktree_path:-}" ]]; then
		local parent_dir
		parent_dir=$(dirname "$repo_root")
		local repo_name
		repo_name=$(basename "$repo_root")
		local slug
		slug=$(echo "$branch_name" | tr '/' '-' | tr '[:upper:]' '[:lower:]')
		worktree_path="${parent_dir}/${repo_name}-${slug}"

		if [[ -d "$worktree_path" ]]; then
			log_info "Using existing worktree: $worktree_path"
		else
			log_info "Creating worktree at: $worktree_path"
			local wt_add_output
			if git show-ref --verify --quiet "refs/heads/$branch_name" 2>/dev/null; then
				wt_add_output=$(git worktree add "$worktree_path" "$branch_name" 2>&1) || {
					log_error "Failed to create worktree for $skill_name: ${wt_add_output}"
					return 1
				}
			else
				wt_add_output=$(git worktree add -b "$branch_name" "$worktree_path" 2>&1) || {
					log_error "Failed to create worktree for $skill_name: ${wt_add_output}"
					return 1
				}
			fi
			# Register ownership
			register_worktree "$worktree_path" "$branch_name" --task "t1082"
		fi
	fi

	if [[ ! -d "$worktree_path" ]]; then
		log_error "Worktree path does not exist: $worktree_path"
		return 1
	fi

	# Re-import the skill in the worktree context
	log_info "Re-importing $skill_name in worktree..."
	local add_skill_in_wt="${worktree_path}/.agents/scripts/add-skill-helper.sh"
	if [[ ! -x "$add_skill_in_wt" ]]; then
		# Fall back to the deployed helper
		add_skill_in_wt="$ADD_SKILL_HELPER"
	fi

	# Run the import from within the worktree directory
	if ! (cd "$worktree_path" && "$add_skill_in_wt" add "$upstream_url" --force --skip-security 2>&1); then
		log_error "Failed to re-import $skill_name"
		_cleanup_worktree "$worktree_path" "$branch_name"
		return 1
	fi

	# Check if there are actual changes
	if git -C "$worktree_path" diff --quiet && git -C "$worktree_path" diff --cached --quiet; then
		# Also check for untracked files
		local untracked
		untracked=$(git -C "$worktree_path" ls-files --others --exclude-standard 2>/dev/null || echo "")
		if [[ -z "$untracked" ]]; then
			log_info "No changes detected for $skill_name after re-import — skipping"
			_cleanup_worktree "$worktree_path" "$branch_name"
			return 0
		fi
	fi

	# Stage and commit
	git -C "$worktree_path" add -A
	local commit_msg="chore: update ${skill_name} skill from upstream

Upstream: ${upstream_url}
Previous: ${current_commit:0:12}
Latest:   ${latest_commit:0:12}
Updated:  ${timestamp}"

	local commit_output
	commit_output=$(git -C "$worktree_path" commit -m "$commit_msg" --no-verify 2>&1) || {
		log_error "Failed to commit changes for $skill_name: ${commit_output}"
		_cleanup_worktree "$worktree_path" "$branch_name"
		return 1
	}

	log_success "Committed skill update for $skill_name"

	# Push the branch
	local push_output
	push_output=$(git -C "$worktree_path" push -u origin "$branch_name" 2>&1) || {
		log_error "Failed to push branch for $skill_name: ${push_output}"
		return 1
	}

	log_success "Pushed branch: $branch_name"

	# Create PR via gh CLI
	if ! command -v gh &>/dev/null; then
		log_warning "gh CLI not available — branch pushed but PR not created"
		log_info "Create PR manually: gh pr create --head $branch_name"
		return 0
	fi

	local pr_title="chore: update ${skill_name} skill from upstream"
	local pr_body
	pr_body=$(
		cat <<PREOF
## Skill Update: ${skill_name}

Automated skill update from upstream source.

| Field | Value |
|-------|-------|
| Skill | \`${skill_name}\` |
| Source | ${upstream_url} |
| Previous commit | \`${current_commit:0:12}\` |
| Latest commit | \`${latest_commit:0:12}\` |

### Review checklist

- [ ] Verify the updated skill content is correct
- [ ] Check for breaking changes in the skill format
- [ ] Confirm security scan passes (re-run if needed)

---
*Generated by \`skill-update-helper.sh pr\` (t1082)*
PREOF
	)

	local pr_url
	local pr_create_output
	pr_create_output=$(gh pr create \
		--head "$branch_name" \
		--base "$default_branch" \
		--title "$pr_title" \
		--body "$pr_body" \
		--repo "$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || echo '')" \
		2>&1) || {
		log_error "Failed to create PR for $skill_name: ${pr_create_output}"
		log_info "Branch is pushed — create PR manually: gh pr create --head $branch_name"
		return 1
	}
	pr_url="$pr_create_output"

	log_success "PR created for $skill_name: $pr_url"
	return 0
}

# Clean up a worktree on failure (only if we created it)
_cleanup_worktree() {
	local wt_path="$1"
	local branch="$2"

	# Only clean up if the worktree has no commits beyond the base
	local default_branch
	default_branch=$(get_default_branch)
	local ahead
	ahead=$(git -C "$wt_path" rev-list --count "${default_branch}..HEAD" 2>/dev/null || echo "0")

	if [[ "$ahead" -eq 0 ]]; then
		log_info "Cleaning up empty worktree: $wt_path"
		git worktree remove "$wt_path" --force 2>/dev/null || true
		git branch -D "$branch" 2>/dev/null || true
		unregister_worktree "$wt_path"
	fi
	return 0
}

# Orchestrator: check all skills and create PRs for those with updates
cmd_pr() {
	local target_skill="${1:-}"

	require_jq

	local skill_count
	skill_count=$(check_skill_sources)

	log_info "Checking $skill_count imported skill(s) for upstream updates..."
	echo ""

	# Require gh CLI for PR creation (unless dry-run)
	if [[ "$DRY_RUN" != true ]] && ! command -v gh &>/dev/null; then
		log_error "gh CLI is required for PR creation"
		log_info "Install with: brew install gh (macOS) or see https://cli.github.com/"
		return 1
	fi

	# Ensure we're on the default branch in the main repo
	local current_branch
	current_branch=$(git branch --show-current 2>/dev/null || echo "")
	local default_branch
	default_branch=$(get_default_branch)

	if [[ "$DRY_RUN" != true && "$current_branch" != "$default_branch" ]]; then
		log_warning "Not on $default_branch (on $current_branch) — worktrees will branch from $default_branch"
	fi

	local prs_created=0
	local prs_skipped=0
	local prs_failed=0

	while IFS= read -r skill_json; do
		local name upstream_url current_commit
		name=$(echo "$skill_json" | jq -r '.name')
		upstream_url=$(echo "$skill_json" | jq -r '.upstream_url')
		current_commit=$(echo "$skill_json" | jq -r '.upstream_commit // empty')

		# Filter to specific skill if requested
		if [[ -n "$target_skill" && "$name" != "$target_skill" ]]; then
			continue
		fi

		# Skip non-GitHub sources (ClawdHub, etc.) — no git commit to compare
		if [[ "$upstream_url" != *"github.com"* ]]; then
			if [[ "$QUIET" != true ]]; then
				log_info "Skipping $name (non-GitHub source: ${upstream_url})"
			fi
			((prs_skipped++)) || true
			continue
		fi

		# Parse owner/repo from URL
		local owner_repo
		owner_repo=$(parse_github_url "$upstream_url")
		owner_repo=$(echo "$owner_repo" | cut -d'/' -f1-2)

		if [[ -z "$owner_repo" || "$owner_repo" == "/" ]]; then
			log_warning "Could not parse URL for $name: $upstream_url — skipping"
			((prs_skipped++)) || true
			continue
		fi

		# Get latest commit
		local latest_commit
		if ! latest_commit=$(get_latest_commit "$owner_repo"); then
			log_warning "Could not fetch latest commit for $name ($owner_repo) — skipping"
			((prs_skipped++)) || true
			continue
		fi

		# Update last_checked timestamp
		update_last_checked "$name"

		# Skip if up to date
		if [[ -n "$current_commit" && "$latest_commit" == "$current_commit" ]]; then
			if [[ "$QUIET" != true ]]; then
				echo -e "${GREEN}Up to date${NC}: $name"
			fi
			continue
		fi

		# Skill has an update — create PR
		if cmd_pr_single "$name" "$upstream_url" "$current_commit" "$latest_commit"; then
			((prs_created++)) || true
		else
			((prs_failed++)) || true
		fi

	done < <(jq -c '.skills[]' "$SKILL_SOURCES")

	# Summary
	echo ""
	echo "PR Pipeline Summary:"
	echo "  PRs created: $prs_created"
	if [[ $prs_skipped -gt 0 ]]; then
		echo "  Skipped: $prs_skipped"
	fi
	if [[ $prs_failed -gt 0 ]]; then
		echo "  Failed: $prs_failed"
	fi

	if [[ $prs_failed -gt 0 ]]; then
		return 1
	fi
	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	local command="check"
	local skill_name=""

	# Parse arguments using named variable for clarity (S7679)
	local arg
	while [[ $# -gt 0 ]]; do
		arg="$1"
		case "$arg" in
		check | update | status | pr)
			command="$arg"
			shift
			;;
		--auto-update)
			AUTO_UPDATE=true
			shift
			;;
		--quiet | -q)
			QUIET=true
			shift
			;;
		--json)
			JSON_OUTPUT=true
			shift
			;;
		--dry-run)
			DRY_RUN=true
			shift
			;;
		--help | -h)
			show_help
			exit 0
			;;
		-*)
			log_error "Unknown option: $arg"
			show_help
			exit 1
			;;
		*)
			# Assume it's a skill name for update/pr command
			skill_name="$arg"
			shift
			;;
		esac
	done

	case "$command" in
	check)
		cmd_check
		;;
	update)
		cmd_update "$skill_name"
		;;
	status)
		cmd_status
		;;
	pr)
		cmd_pr "$skill_name"
		;;
	*)
		log_error "Unknown command: $command"
		show_help
		exit 1
		;;
	esac
}

main "$@"
