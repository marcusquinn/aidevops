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
#   --auto-update        Automatically update skills with changes
#   --quiet              Suppress non-essential output
#   --non-interactive    Headless mode: log to auto-update.log, no prompts, graceful errors
#   --json               Output in JSON format
#   --dry-run            Show what would be done without making changes
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
NON_INTERACTIVE=false
JSON_OUTPUT=false
DRY_RUN=false
# Batch mode for PR creation: one-per-skill (default) or single-pr
BATCH_MODE="${SKILL_UPDATE_BATCH_MODE:-one-per-skill}"

# Log file for non-interactive / headless mode (shared with auto-update-helper.sh)
readonly SKILL_LOG_FILE="${HOME}/.aidevops/logs/auto-update.log"

# Worktree helper
WORKTREE_HELPER="${SCRIPT_DIR}/worktree-helper.sh"

# =============================================================================
# Helper Functions
# =============================================================================

# Write a timestamped entry to the shared auto-update log file.
# Used in non-interactive mode so headless callers (cron, auto-update-helper.sh)
# can inspect results without parsing stdout.
_log_to_file() {
	local level="$1"
	shift
	local timestamp
	timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
	mkdir -p "$(dirname "$SKILL_LOG_FILE")" 2>/dev/null || true
	echo "[$timestamp] [skill-update] [$level] $*" >>"$SKILL_LOG_FILE"
	return 0
}

log_info() {
	if [[ "$NON_INTERACTIVE" == true ]]; then
		_log_to_file "INFO" "$1"
	elif [[ "$QUIET" != true ]]; then
		echo -e "${BLUE}[skill-update]${NC} $1"
	fi
	return 0
}

log_success() {
	if [[ "$NON_INTERACTIVE" == true ]]; then
		_log_to_file "INFO" "$1"
	elif [[ "$QUIET" != true ]]; then
		echo -e "${GREEN}[OK]${NC} $1"
	fi
	return 0
}

log_warning() {
	if [[ "$NON_INTERACTIVE" == true ]]; then
		_log_to_file "WARN" "$1"
	else
		echo -e "${YELLOW}[WARN]${NC} $1"
	fi
	return 0
}

log_error() {
	if [[ "$NON_INTERACTIVE" == true ]]; then
		_log_to_file "ERROR" "$1"
	else
		echo -e "${RED}[ERROR]${NC} $1"
	fi
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
    --auto-update                Automatically update skills with changes
    --quiet                      Suppress non-essential output
    --non-interactive            Headless mode: redirect all output to auto-update.log,
                                   suppress prompts, treat errors as non-fatal (exit 0)
                                   Implies --quiet. Designed for cron / auto-update-helper.sh.
    --json                       Output results in JSON format
    --dry-run                    Show what would be done without making changes
    --batch-mode <mode>          PR batching strategy (default: one-per-skill)
                                   one-per-skill  One PR per updated skill (independent review)
                                   single-pr      All updated skills in one PR (batch review)

ENVIRONMENT:
    SKILL_UPDATE_BATCH_MODE      Set default batch mode (one-per-skill|single-pr)

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

    # Create PRs for all skills with updates (one PR per skill, default)
    skill-update-helper.sh pr

    # Create a single PR for all updated skills
    skill-update-helper.sh pr --batch-mode single-pr

    # Create PR for a specific skill
    skill-update-helper.sh pr cloudflare

    # Preview what PRs would be created
    skill-update-helper.sh pr --dry-run

CRON EXAMPLE:
    # Weekly update check (Sundays at 3am)
    0 3 * * 0 ~/.aidevops/agents/scripts/skill-update-helper.sh check --quiet

    # Headless auto-update (called by auto-update-helper.sh)
    skill-update-helper.sh check --auto-update --quiet --non-interactive
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
	[[ "$NON_INTERACTIVE" != true ]] && echo ""

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
			if [[ "$NON_INTERACTIVE" != true ]]; then
				echo -e "${YELLOW}UNKNOWN${NC}: $name (no commit recorded)"
				echo "  Source: $upstream_url"
				echo "  Latest: ${latest_commit:0:7}"
				echo ""
			fi
			log_info "UNKNOWN: $name (no commit recorded) latest=${latest_commit:0:7}"
			((updates_available++)) || true
			results+=("{\"name\":\"$name\",\"status\":\"unknown\",\"latest\":\"$latest_commit\"}")
		elif [[ "$latest_commit" != "$current_commit" ]]; then
			if [[ "$NON_INTERACTIVE" != true ]]; then
				echo -e "${YELLOW}UPDATE AVAILABLE${NC}: $name"
				echo "  Current: ${current_commit:0:7}"
				echo "  Latest:  ${latest_commit:0:7}"
				echo "  Run: aidevops skill update $name"
				echo ""
			fi
			log_info "UPDATE AVAILABLE: $name current=${current_commit:0:7} latest=${latest_commit:0:7}"
			((updates_available++)) || true
			results+=("{\"name\":\"$name\",\"status\":\"update_available\",\"current\":\"$current_commit\",\"latest\":\"$latest_commit\"}")

			# Auto-update if enabled
			if [[ "$AUTO_UPDATE" == true ]]; then
				log_info "Auto-updating $name..."
				# In non-interactive mode: close stdin to prevent any prompts from add-skill-helper.sh
				local add_exit=0
				if [[ "$NON_INTERACTIVE" == true ]]; then
					"$ADD_SKILL_HELPER" add "$upstream_url" --force </dev/null >>"$SKILL_LOG_FILE" 2>&1 || add_exit=$?
				else
					"$ADD_SKILL_HELPER" add "$upstream_url" --force || add_exit=$?
				fi
				if [[ "$add_exit" -eq 0 ]]; then
					log_success "Updated $name"
				else
					log_error "Failed to update $name (exit $add_exit)"
				fi
			fi
		else
			if [[ "$NON_INTERACTIVE" != true ]]; then
				echo -e "${GREEN}Up to date${NC}: $name"
			fi
			log_info "Up to date: $name commit=${current_commit:0:7}"
			((up_to_date++)) || true
			results+=("{\"name\":\"$name\",\"status\":\"up_to_date\",\"commit\":\"$current_commit\"}")
		fi

	done < <(jq -c '.skills[]' "$SKILL_SOURCES")

	# Summary
	if [[ "$NON_INTERACTIVE" != true ]]; then
		echo ""
		echo "Summary:"
		echo "  Up to date: $up_to_date"
		echo "  Updates available: $updates_available"
		if [[ $check_failed -gt 0 ]]; then
			echo "  Check failed: $check_failed"
		fi
	fi
	log_info "Summary: up_to_date=$up_to_date updates_available=$updates_available check_failed=$check_failed"

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
	# In non-interactive mode, auto-update-helper.sh treats exit 1 as "updates applied" (not an error)
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
# PR Template Helpers — conventional commit, changelog, diff summary (t1082.4)
# =============================================================================

# Fetch upstream commits between two SHAs from GitHub API.
# Arguments:
#   $1 - owner/repo (e.g. "dmmulroy/cloudflare-skill")
#   $2 - base SHA (previous import commit, may be empty)
#   $3 - head SHA (latest upstream commit)
# Outputs: markdown list of commits, one per line
# Returns: 0 always (empty output on failure)
get_upstream_changelog() {
	local owner_repo="$1"
	local base_sha="$2"
	local head_sha="$3"

	if [[ -z "$owner_repo" || -z "$head_sha" ]]; then
		return 0
	fi

	local api_url
	local response

	# If we have a base SHA, use the compare endpoint for precise range
	if [[ -n "$base_sha" ]]; then
		api_url="https://api.github.com/repos/${owner_repo}/compare/${base_sha}...${head_sha}"
		response=$(curl -s --connect-timeout 10 --max-time 30 \
			-H "Accept: application/vnd.github.v3+json" "$api_url" 2>/dev/null)

		if [[ -n "$response" ]]; then
			local commits_json
			commits_json=$(echo "$response" | jq -r '.commits // empty' 2>/dev/null)
			if [[ -n "$commits_json" && "$commits_json" != "null" ]]; then
				echo "$response" | jq -r '
					.commits[]? |
					"- [`\(.sha[0:7])`](\(.html_url)) \(.commit.message | split("\n")[0]) — \(.commit.author.name)"
				' 2>/dev/null || true
				return 0
			fi
		fi
	fi

	# Fallback: list recent commits on the repo (up to 20)
	api_url="https://api.github.com/repos/${owner_repo}/commits?per_page=20&sha=${head_sha}"
	response=$(curl -s --connect-timeout 10 --max-time 30 \
		-H "Accept: application/vnd.github.v3+json" "$api_url" 2>/dev/null)

	if [[ -n "$response" ]]; then
		echo "$response" | jq -r '
			.[]? |
			"- [`\(.sha[0:7])`](\(.html_url)) \(.commit.message | split("\n")[0]) — \(.commit.author.name)"
		' 2>/dev/null | head -20 || true
	fi

	return 0
}

# Summarise file-level changes in the worktree after re-import.
# Arguments:
#   $1 - worktree path
#   $2 - default branch (base for diff)
# Outputs: markdown summary of added/modified/deleted files
# Returns: 0 always
get_skill_diff_summary() {
	local worktree_path="$1"
	local default_branch="${2:-main}"

	if [[ ! -d "$worktree_path" ]]; then
		return 0
	fi

	local diff_stat
	diff_stat=$(git -C "$worktree_path" diff --stat "${default_branch}..HEAD" 2>/dev/null || true)

	if [[ -z "$diff_stat" ]]; then
		# Try staged diff if no committed diff yet
		diff_stat=$(git -C "$worktree_path" diff --cached --stat 2>/dev/null || true)
	fi

	if [[ -z "$diff_stat" ]]; then
		echo "_No file changes detected._"
		return 0
	fi

	# Format as code block for readability
	printf '```\n%s\n```\n' "$diff_stat"
	return 0
}

# Generate a conventional commit message for a skill update.
# Arguments:
#   $1 - skill name
#   $2 - upstream URL
#   $3 - current (previous) commit SHA (may be empty)
#   $4 - latest commit SHA
#   $5 - changelog lines (multi-line string, may be empty)
# Outputs: commit message string
# Returns: 0 always
generate_skill_commit_msg() {
	local skill_name="$1"
	local upstream_url="$2"
	local current_commit="$3"
	local latest_commit="$4"
	local changelog="$5"

	local timestamp
	timestamp=$(date -u +"%Y-%m-%d")

	# Conventional commit: chore(skill/<name>): update from upstream
	local subject="chore(skill/${skill_name}): update from upstream (${latest_commit:0:7})"

	local prev_short
	prev_short="${current_commit:0:12}"
	[[ -z "$prev_short" ]] && prev_short="(none)"

	local body
	body="Upstream: ${upstream_url}
Previous: ${prev_short}
Latest:   ${latest_commit:0:12}
Updated:  ${timestamp}"

	# Append changelog if available (trimmed to avoid huge commits)
	if [[ -n "$changelog" ]]; then
		local changelog_lines
		changelog_lines=$(echo "$changelog" | wc -l | tr -d ' ')
		if [[ "$changelog_lines" -gt 15 ]]; then
			# Truncate to first 15 commits with a note
			local truncated
			truncated=$(echo "$changelog" | head -15)
			body="${body}

Upstream changes (first 15 of ${changelog_lines}):
${truncated}
... and $((changelog_lines - 15)) more commits"
		elif [[ "$changelog_lines" -gt 0 ]]; then
			body="${body}

Upstream changes:
${changelog}"
		fi
	fi

	printf '%s\n\n%s\n' "$subject" "$body"
	return 0
}

# Generate the full PR body for a skill update.
# Arguments:
#   $1 - skill name
#   $2 - upstream URL
#   $3 - current (previous) commit SHA (may be empty)
#   $4 - latest commit SHA
#   $5 - changelog lines (multi-line string, may be empty)
#   $6 - diff summary (multi-line string, may be empty)
# Outputs: PR body markdown
# Returns: 0 always
generate_skill_pr_body() {
	local skill_name="$1"
	local upstream_url="$2"
	local current_commit="$3"
	local latest_commit="$4"
	local changelog="$5"
	local diff_summary="$6"

	local prev_display="${current_commit:0:12}"
	[[ -z "$prev_display" ]] && prev_display="_(none — first import)_"

	cat <<PREOF
## Skill Update: \`${skill_name}\`

Automated skill update from upstream source.

| Field | Value |
|-------|-------|
| Skill | \`${skill_name}\` |
| Source | ${upstream_url} |
| Previous commit | \`${prev_display}\` |
| Latest commit | \`${latest_commit:0:12}\` |

### Upstream changelog

PREOF

	if [[ -n "$changelog" ]]; then
		echo "$changelog"
	else
		echo "_Could not fetch upstream changelog (API unavailable or no base commit)._"
	fi

	cat <<PREOF

### Diff summary

PREOF

	if [[ -n "$diff_summary" ]]; then
		echo "$diff_summary"
	else
		echo "_No diff available._"
	fi

	cat <<PREOF

### Review checklist

- [ ] Verify the updated skill content is correct
- [ ] Check for breaking changes in the skill format
- [ ] Confirm security scan passes (re-run if needed)

---
*Generated by \`skill-update-helper.sh pr\` (t1082.4)*
PREOF

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
			register_worktree "$worktree_path" "$branch_name"
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

	# Fetch upstream changelog (commits between previous and latest)
	local owner_repo_for_log
	owner_repo_for_log=$(parse_github_url "$upstream_url")
	owner_repo_for_log=$(echo "$owner_repo_for_log" | cut -d'/' -f1-2)
	local changelog=""
	if [[ -n "$owner_repo_for_log" && "$owner_repo_for_log" != "/" ]]; then
		log_info "Fetching upstream changelog for $skill_name..."
		changelog=$(get_upstream_changelog "$owner_repo_for_log" "$current_commit" "$latest_commit" 2>/dev/null || true)
	fi

	# Stage changes and capture diff summary before committing
	git -C "$worktree_path" add -A
	local diff_summary
	diff_summary=$(get_skill_diff_summary "$worktree_path" "$default_branch")

	# Generate conventional commit message with changelog
	local commit_msg
	commit_msg=$(generate_skill_commit_msg \
		"$skill_name" "$upstream_url" "$current_commit" "$latest_commit" "$changelog")

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

	local pr_title="chore(skill/${skill_name}): update from upstream (${latest_commit:0:7})"
	local pr_body
	pr_body=$(generate_skill_pr_body \
		"$skill_name" "$upstream_url" "$current_commit" "$latest_commit" \
		"$changelog" "$diff_summary")

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

# =============================================================================
# Batch PR Pipeline — collect all updated skills into a single PR (t1082.3)
# =============================================================================

# Create one PR containing updates for all skills that have upstream changes.
# Arguments:
#   $1 - target skill name (optional; empty = all skills)
# Returns: 0 on success, 1 on failure
cmd_pr_batch() {
	local target_skill="${1:-}"

	require_jq

	local skill_count
	skill_count=$(check_skill_sources)

	log_info "Checking $skill_count imported skill(s) for upstream updates (batch mode)..."
	echo ""

	# Require gh CLI for PR creation (unless dry-run)
	if [[ "$DRY_RUN" != true ]] && ! command -v gh &>/dev/null; then
		log_error "gh CLI is required for PR creation"
		log_info "Install with: brew install gh (macOS) or see https://cli.github.com/"
		return 1
	fi

	local repo_root
	repo_root=$(get_repo_root)
	if [[ -z "$repo_root" ]]; then
		log_error "Not in a git repository"
		return 1
	fi

	local default_branch
	default_branch=$(get_default_branch)

	# Collect skills that need updates
	local skills_to_update=()
	local skill_urls=()
	local skill_current_commits=()
	local skill_latest_commits=()

	while IFS=$'\t' read -r name upstream_url current_commit; do
		# Filter to specific skill if requested
		if [[ -n "$target_skill" && "$name" != "$target_skill" ]]; then
			continue
		fi

		# Skip non-GitHub sources
		if [[ "$upstream_url" != *"github.com"* ]]; then
			if [[ "$QUIET" != true ]]; then
				log_info "Skipping $name (non-GitHub source: ${upstream_url})"
			fi
			continue
		fi

		# Parse owner/repo from URL
		local owner_repo
		owner_repo=$(parse_github_url "$upstream_url")
		owner_repo=$(echo "$owner_repo" | cut -d'/' -f1-2)

		if [[ -z "$owner_repo" || "$owner_repo" == "/" ]]; then
			log_warning "Could not parse URL for $name: $upstream_url — skipping"
			continue
		fi

		# Get latest commit
		local latest_commit
		if ! latest_commit=$(get_latest_commit "$owner_repo"); then
			log_warning "Could not fetch latest commit for $name ($owner_repo) — skipping"
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

		log_info "Update available: $name (${current_commit:0:7} → ${latest_commit:0:7})"
		skills_to_update+=("$name")
		skill_urls+=("$upstream_url")
		skill_current_commits+=("$current_commit")
		skill_latest_commits+=("$latest_commit")

	done < <(jq -r '.skills[] | [.name, .upstream_url, .upstream_commit // empty] | @tsv' "$SKILL_SOURCES")

	local update_count="${#skills_to_update[@]}"

	if [[ "$update_count" -eq 0 ]]; then
		log_info "No skills require updates — no PR needed"
		return 0
	fi

	log_info "Found $update_count skill(s) with updates"
	echo ""

	# Branch name: chore/skill-update-batch-YYYYMMDD
	local timestamp
	timestamp=$(date -u +"%Y%m%d")
	local branch_name="chore/skill-update-batch-${timestamp}"

	if [[ "$DRY_RUN" == true ]]; then
		log_info "DRY RUN: Would create single batch PR for $update_count skill(s)"
		echo "  Branch: $branch_name"
		for i in "${!skills_to_update[@]}"; do
			echo "  - ${skills_to_update[$i]}: ${skill_current_commits[$i]:0:7} → ${skill_latest_commits[$i]:0:7}"
		done
		echo ""
		return 0
	fi

	# Check if a PR already exists for this branch
	if command -v gh &>/dev/null; then
		local existing_pr
		existing_pr=$(gh pr list --head "$branch_name" --state open --json number --jq '.[0].number' 2>/dev/null || echo "")
		if [[ -n "$existing_pr" ]]; then
			log_warning "PR #${existing_pr} already open for batch branch $branch_name — skipping"
			return 0
		fi
	fi

	# Create worktree for the batch branch
	local worktree_path=""
	if [[ -x "$WORKTREE_HELPER" ]]; then
		local wt_output
		wt_output=$("$WORKTREE_HELPER" add "$branch_name" 2>&1) || {
			if echo "$wt_output" | grep -q "already exists"; then
				worktree_path=$(echo "$wt_output" | grep -oE '/[^ ]+' | head -1)
				log_info "Using existing worktree: $worktree_path"
			else
				log_error "Failed to create worktree for batch: $wt_output"
				return 1
			fi
		}
		if [[ -z "${worktree_path:-}" ]]; then
			worktree_path=$(echo "$wt_output" | grep "^Path:" | sed 's/^Path: *//' | head -1)
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
			log_info "Creating batch worktree at: $worktree_path"
			local wt_add_output
			if git show-ref --verify --quiet "refs/heads/$branch_name" 2>/dev/null; then
				wt_add_output=$(git worktree add "$worktree_path" "$branch_name" 2>&1) || {
					log_error "Failed to create batch worktree: ${wt_add_output}"
					return 1
				}
			else
				wt_add_output=$(git worktree add -b "$branch_name" "$worktree_path" 2>&1) || {
					log_error "Failed to create batch worktree: ${wt_add_output}"
					return 1
				}
			fi
			register_worktree "$worktree_path" "$branch_name"
		fi
	fi

	if [[ ! -d "$worktree_path" ]]; then
		log_error "Batch worktree path does not exist: $worktree_path"
		return 1
	fi

	# Re-import each skill in the worktree
	local imported_skills=()
	local failed_skills=()

	for i in "${!skills_to_update[@]}"; do
		local skill_name="${skills_to_update[$i]}"
		local upstream_url="${skill_urls[$i]}"

		log_info "Re-importing $skill_name in batch worktree..."
		local add_skill_in_wt="${worktree_path}/.agents/scripts/add-skill-helper.sh"
		if [[ ! -x "$add_skill_in_wt" ]]; then
			add_skill_in_wt="$ADD_SKILL_HELPER"
		fi

		if (cd "$worktree_path" && "$add_skill_in_wt" add "$upstream_url" --force --skip-security 2>&1); then
			log_success "Re-imported $skill_name"
			imported_skills+=("$skill_name")
		else
			log_error "Failed to re-import $skill_name — skipping"
			failed_skills+=("$skill_name")
		fi
	done

	if [[ "${#imported_skills[@]}" -eq 0 ]]; then
		log_error "No skills were successfully imported — aborting batch PR"
		_cleanup_worktree "$worktree_path" "$branch_name"
		return 1
	fi

	# Check if there are actual changes
	if git -C "$worktree_path" diff --quiet && git -C "$worktree_path" diff --cached --quiet; then
		local untracked
		untracked=$(git -C "$worktree_path" ls-files --others --exclude-standard 2>/dev/null || echo "")
		if [[ -z "$untracked" ]]; then
			log_info "No changes detected after re-importing all skills — skipping"
			_cleanup_worktree "$worktree_path" "$branch_name"
			return 0
		fi
	fi

	# Stage and commit all changes
	git -C "$worktree_path" add -A

	# Build commit message listing all updated skills
	local commit_msg="chore: batch update ${#imported_skills[@]} skill(s) from upstream (t1082.3)"$'\n'$'\n'
	# bash 3.2-compatible: newline-separated string instead of associative array
	local imported_skills_list=""
	for imp in "${imported_skills[@]}"; do
		imported_skills_list="${imported_skills_list:+$imported_skills_list
}$imp"
	done
	for i in "${!skills_to_update[@]}"; do
		local sname="${skills_to_update[$i]}"
		# Only include successfully imported skills
		if echo "$imported_skills_list" | grep -qxF "$sname"; then
			commit_msg+="- ${sname}: ${skill_current_commits[$i]:0:12} → ${skill_latest_commits[$i]:0:12}"$'\n'
		fi
	done
	commit_msg+="Updated: ${timestamp}"

	local commit_output
	commit_output=$(git -C "$worktree_path" commit -m "$commit_msg" --no-verify 2>&1) || {
		log_error "Failed to commit batch changes: ${commit_output}"
		_cleanup_worktree "$worktree_path" "$branch_name"
		return 1
	}

	log_success "Committed batch skill updates"

	# Push the branch
	local push_output
	push_output=$(git -C "$worktree_path" push -u origin "$branch_name" 2>&1) || {
		log_error "Failed to push batch branch: ${push_output}"
		return 1
	}

	log_success "Pushed batch branch: $branch_name"

	# Create PR via gh CLI
	if ! command -v gh &>/dev/null; then
		log_warning "gh CLI not available — branch pushed but PR not created"
		log_info "Create PR manually: gh pr create --head $branch_name"
		return 0
	fi

	# Build PR body with table of all updated skills
	local pr_title="chore: batch update ${#imported_skills[@]} skill(s) from upstream"
	local skill_table="| Skill | Previous | Latest | Source |"$'\n'
	skill_table+="|-------|----------|--------|--------|"$'\n'
	for i in "${!skills_to_update[@]}"; do
		local sname="${skills_to_update[$i]}"
		# Reuse the imported_skills_list built for the commit message lookup
		if echo "$imported_skills_list" | grep -qxF "$sname"; then
			skill_table+="| \`${sname}\` | \`${skill_current_commits[$i]:0:12}\` | \`${skill_latest_commits[$i]:0:12}\` | ${skill_urls[$i]} |"$'\n'
		fi
	done

	local failed_note=""
	if [[ "${#failed_skills[@]}" -gt 0 ]]; then
		failed_note=$'\n'"**Note**: The following skills failed to re-import and are NOT included in this PR: ${failed_skills[*]}"$'\n'
	fi

	local pr_body
	pr_body="## Batch Skill Update

Automated batch update of ${#imported_skills[@]} skill(s) from upstream sources.

${skill_table}
${failed_note}
### Review checklist

- [ ] Verify each updated skill content is correct
- [ ] Check for breaking changes in skill formats
- [ ] Confirm security scan passes (re-run if needed)

---
*Generated by \`skill-update-helper.sh pr --batch-mode single-pr\`*"

	local repo_name_with_owner
	repo_name_with_owner=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)
	local pr_create_args=("--head" "$branch_name" "--base" "$default_branch" "--title" "$pr_title" "--body" "$pr_body")
	if [[ -n "$repo_name_with_owner" ]]; then
		pr_create_args+=("--repo" "$repo_name_with_owner")
	fi
	local pr_create_output
	pr_create_output=$(gh pr create "${pr_create_args[@]}" 2>&1) || {
		log_error "Failed to create batch PR: ${pr_create_output}"
		log_info "Branch is pushed — create PR manually: gh pr create --head $branch_name"
		return 1
	}

	log_success "Batch PR created: $pr_create_output"

	echo ""
	echo "Batch PR Summary:"
	echo "  Skills updated: ${#imported_skills[@]}"
	if [[ "${#failed_skills[@]}" -gt 0 ]]; then
		echo "  Skills failed:  ${#failed_skills[@]} (${failed_skills[*]})"
	fi
	echo "  PR: $pr_create_output"

	if [[ "${#failed_skills[@]}" -gt 0 ]]; then
		return 1
	fi
	return 0
}

# Orchestrator: check all skills and create PRs for those with updates.
# Dispatches to cmd_pr_batch (single-pr mode) or iterates cmd_pr_single
# (one-per-skill mode, default) based on BATCH_MODE.
cmd_pr() {
	local target_skill="${1:-}"

	# Dispatch to batch mode if configured
	if [[ "$BATCH_MODE" == "single-pr" ]]; then
		log_info "Batch mode: single-pr — all updated skills will be combined into one PR"
		cmd_pr_batch "$target_skill"
		return $?
	fi

	# Default: one-per-skill
	require_jq

	local skill_count
	skill_count=$(check_skill_sources)

	log_info "Checking $skill_count imported skill(s) for upstream updates (one PR per skill)..."
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
		--non-interactive)
			NON_INTERACTIVE=true
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
		--batch-mode)
			if [[ $# -lt 2 ]]; then
				log_error "--batch-mode requires a value: one-per-skill or single-pr"
				exit 1
			fi
			BATCH_MODE="$2"
			if [[ "$BATCH_MODE" != "one-per-skill" && "$BATCH_MODE" != "single-pr" ]]; then
				log_error "Invalid --batch-mode value: $BATCH_MODE (must be one-per-skill or single-pr)"
				exit 1
			fi
			shift 2
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

	# In non-interactive mode, install an ERR trap so unexpected errors are
	# logged to auto-update.log and the process exits cleanly (exit 0) rather
	# than crashing with no log entry.  The trap must be set after arg parsing
	# so that NON_INTERACTIVE is already true when it fires.
	if [[ "$NON_INTERACTIVE" == true ]]; then
		trap '_non_interactive_error_handler $LINENO' ERR
		log_info "Starting skill-update-helper.sh in non-interactive mode (command=$command)"
	fi

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

# Error handler for non-interactive mode — logs the failure and exits cleanly.
# Defined at file scope so it is available when the trap fires.
_non_interactive_error_handler() {
	local exit_code="$?"
	local line_no="${1:-unknown}"
	_log_to_file "ERROR" "Unexpected error at line ${line_no} (exit ${exit_code}) — skill-update-helper.sh aborted"
	exit 0
}

main "$@"
