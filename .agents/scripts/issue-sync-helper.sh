#!/usr/bin/env bash
# shellcheck disable=SC2155
# =============================================================================
# aidevops Issue Sync Helper
# =============================================================================
# Bi-directional sync between TODO.md/PLANS.md and platform issues.
# Supports GitHub (gh CLI), Gitea (REST API), and GitLab (REST API).
# Composes rich issue bodies with subtasks, plan context, and PRD links.
#
# Usage: issue-sync-helper.sh [command] [options]
#
# Commands:
#   push [tNNN]     Create/update issues from TODO.md tasks
#   enrich [tNNN]   Update existing issue bodies with full context
#   pull            Sync issue refs back to TODO.md + detect orphan issues
#   close [tNNN]    Close issue when TODO.md task is [x]
#   reconcile       Fix mismatched ref:GH# values and detect drift
#   status          Show sync drift between TODO.md and platform
#   parse [tNNN]    Parse and display task context (dry-run)
#   help            Show this help message
#
# Options:
#   --repo SLUG     Override repo slug (default: auto-detect from git remote)
#   --platform P    Override platform (github|gitea|gitlab, default: auto-detect)
#   --dry-run       Show what would be done without making changes
#   --verbose       Show detailed output
#
# Part of aidevops framework: https://aidevops.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"
source "${SCRIPT_DIR}/issue-sync-lib.sh"

# =============================================================================
# Configuration
# =============================================================================

VERBOSE="${VERBOSE:-false}"
DRY_RUN="${DRY_RUN:-false}"
FORCE_CLOSE="${FORCE_CLOSE:-false}"
REPO_SLUG=""
PLATFORM="" # github, gitea, gitlab — auto-detected if empty

# Supervisor DB path — used for cross-repo task ownership checks (t1235).
# The supervisor stores each task's repo path in tasks.repo.
# When issue-sync runs from one repo but TODO.md contains tasks from other
# repos (cross-repo DB), we must skip tasks that belong to other repos.
SUPERVISOR_DB="${SUPERVISOR_DB:-${HOME}/.aidevops/.agent-workspace/supervisor/supervisor.db}"

# =============================================================================
# Utility Functions
# =============================================================================

log_verbose() {
	if [[ "$VERBOSE" == "true" ]]; then
		print_info "$1"
	fi
	return 0
}

#######################################
# t1324: AI-based semantic duplicate detection (standalone)
#
# Checks if a new issue title semantically duplicates any existing open issue.
# Self-contained — does not depend on supervisor modules.
#
# Args:
#   $1 - new issue title
#   $2 - repo_slug
#
# Stdout: existing issue number if duplicate found
# Returns: 0 if duplicate found, 1 if not
#######################################
_ai_check_duplicate() {
	local new_title="$1"
	local repo_slug="$2"

	# Resolve AI CLI (claude preferred, opencode fallback)
	local ai_cli=""
	if command -v claude &>/dev/null; then
		ai_cli="claude"
	elif command -v opencode &>/dev/null; then
		ai_cli="opencode"
	else
		return 1 # No AI available
	fi

	# Fetch recent open issues
	local existing_issues
	existing_issues=$(gh issue list --repo "$repo_slug" --state open --limit 50 \
		--json number,title,labels \
		--jq '.[] | "#\(.number): \(.title) [\(.labels | map(.name) | join(","))]"' \
		2>/dev/null || echo "")

	if [[ -z "$existing_issues" ]]; then
		return 1
	fi

	local prompt
	prompt="You are a duplicate issue detector. Determine if a new issue is a semantic duplicate of any existing open issue.

NEW ISSUE TITLE: ${new_title}

EXISTING OPEN ISSUES:
${existing_issues}

RULES:
- A duplicate means the same work described differently (different task IDs, rephrased titles).
- Different task IDs (e.g., t10 vs t023) for the same work ARE duplicates.
- Related but different-scope issues are NOT duplicates.
- Auto-generated dashboard/status issues are never duplicates of task issues.
- When uncertain, prefer false (not duplicate).

Respond with ONLY a JSON object:
{\"duplicate\": true|false, \"duplicate_of\": \"#NNN or empty\", \"reason\": \"one sentence\"}"

	local ai_result=""
	if [[ "$ai_cli" == "opencode" ]]; then
		ai_result=$(timeout 15 opencode run \
			-m "anthropic/claude-sonnet-4-20250514" \
			--format default \
			--title "dedup-$$" \
			"$prompt" 2>/dev/null || echo "")
		ai_result=$(printf '%s' "$ai_result" | sed 's/\x1b\[[0-9;]*[mGKHF]//g; s/\x1b\[[0-9;]*[A-Za-z]//g; s/\x1b\]//g; s/\x07//g')
	else
		ai_result=$(timeout 15 claude \
			-p "$prompt" \
			--model "claude-sonnet-4-20250514" \
			--output-format text 2>/dev/null || echo "")
	fi

	if [[ -z "$ai_result" ]]; then
		return 1
	fi

	local json_block
	json_block=$(printf '%s' "$ai_result" | grep -oE '\{[^}]+\}' | head -1)
	if [[ -z "$json_block" ]]; then
		return 1
	fi

	local is_duplicate
	is_duplicate=$(printf '%s' "$json_block" | jq -r '.duplicate // false' 2>/dev/null || echo "false")
	local duplicate_of
	duplicate_of=$(printf '%s' "$json_block" | jq -r '.duplicate_of // ""' 2>/dev/null | tr -d '#')

	if [[ "$is_duplicate" == "true" && -n "$duplicate_of" && "$duplicate_of" =~ ^[0-9]+$ ]]; then
		local reason
		reason=$(printf '%s' "$json_block" | jq -r '.reason // ""' 2>/dev/null || echo "")
		print_warning "Semantic duplicate: $new_title duplicates #${duplicate_of} — $reason"
		echo "$duplicate_of"
		return 0
	fi

	return 1
}

# Derive the repo slug for a task from the supervisor DB (t1235).
# Returns the slug (owner/repo) on stdout, or empty string if:
#   - SUPERVISOR_DB is not set / does not exist
#   - The task has no DB record
#   - The DB repo path cannot be resolved to a git remote
# Arguments:
#   $1 - task_id (e.g. t1235)
# Returns: 0 always (caller decides how to handle empty result)
_get_task_repo_slug_from_db() {
	local task_id="$1"
	if [[ -z "${SUPERVISOR_DB:-}" || ! -f "${SUPERVISOR_DB:-}" ]]; then
		return 0
	fi
	local db_repo_path
	db_repo_path=$(sqlite3 -cmd ".timeout 5000" "$SUPERVISOR_DB" \
		"SELECT repo FROM tasks WHERE id = '$(printf '%s' "$task_id" | sed "s/'/''/g")' AND repo IS NOT NULL AND repo != '' LIMIT 1;" \
		2>/dev/null || echo "")
	if [[ -z "$db_repo_path" ]]; then
		return 0
	fi
	local canonical_path
	canonical_path=$(realpath "$db_repo_path" 2>/dev/null || echo "")
	if [[ -z "$canonical_path" ]]; then
		return 0
	fi
	detect_repo_slug "$canonical_path" 2>/dev/null || true
	return 0
}

# strip_code_fences, find_project_root — sourced from issue-sync-lib.sh

# Detect repo slug from git remote
detect_repo_slug() {
	local project_root="$1"
	local slug
	local remote_url
	remote_url=$(git -C "$project_root" remote get-url origin 2>/dev/null || echo "")
	# Handle both HTTPS (github.com/owner/repo.git) and SSH (git@github.com:owner/repo.git)
	remote_url="${remote_url%.git}" # Strip .git suffix
	slug=$(echo "$remote_url" | sed -E 's|.*[:/]([^/]+/[^/]+)$|\1|' || echo "")
	if [[ -z "$slug" ]]; then
		print_error "Could not detect GitHub repo slug from git remote"
		return 1
	fi
	echo "$slug"
	return 0
}

# Resolve a task's repo slug from the supervisor DB (t1235).
# When the supervisor manages tasks across multiple repos, each task has a
# repo path stored in the DB. This function looks up that path and derives
# the repo slug from its git remote — ensuring issues are created in the
# correct repo, not the CWD repo.
# Returns: repo slug on stdout, or empty string if DB unavailable/task not found.
# $1: task_id
_lookup_task_repo_slug() {
	local task_id="$1"
	local supervisor_db="${SUPERVISOR_DB:-$HOME/.aidevops/.agent-workspace/supervisor/supervisor.db}"

	if [[ ! -f "$supervisor_db" ]]; then
		return 0
	fi

	# Look up the task's repo path from the supervisor DB
	local db_repo_path=""
	db_repo_path=$(sqlite3 "$supervisor_db" \
		"SELECT repo FROM tasks WHERE id = '$(printf '%s' "$task_id" | sed "s/'/''/g")' AND repo IS NOT NULL AND repo != '' LIMIT 1;" \
		2>/dev/null || echo "")

	if [[ -z "$db_repo_path" ]]; then
		return 0
	fi

	# Resolve to canonical path and derive slug from its git remote
	local canonical_path=""
	canonical_path=$(realpath "$db_repo_path" 2>/dev/null || echo "")
	if [[ -n "$canonical_path" && (-d "$canonical_path/.git" || -f "$canonical_path/.git") ]]; then
		detect_repo_slug "$canonical_path" 2>/dev/null || echo ""
	fi
	return 0
}

# =============================================================================
# Platform Detection (t1120.3)
# =============================================================================

# Detect git platform from remote URL.
# Returns: github, gitea, gitlab, or unknown.
# Detection strategy:
#   1. Explicit --platform flag (PLATFORM variable)
#   2. Known hostnames (github.com, gitlab.com)
#   3. Gitea API probe (GET /api/v1/version — Gitea-specific endpoint)
#   4. GitLab API probe (GET /api/v4/version — GitLab-specific endpoint)
#   5. Fallback to github (most common)
detect_platform() {
	local project_root="$1"

	# If explicitly set, use it
	if [[ -n "$PLATFORM" ]]; then
		echo "$PLATFORM"
		return 0
	fi

	local remote_url
	remote_url=$(git -C "$project_root" remote get-url origin 2>/dev/null || echo "")
	if [[ -z "$remote_url" ]]; then
		echo "github"
		return 0
	fi

	# Extract hostname from remote URL
	local hostname=""
	if [[ "$remote_url" == git@* ]]; then
		# SSH: git@hostname:owner/repo.git
		hostname="${remote_url#git@}"
		hostname="${hostname%%:*}"
	elif [[ "$remote_url" == ssh://* ]]; then
		# SSH: ssh://git@hostname/owner/repo.git
		hostname="${remote_url#ssh://}"
		hostname="${hostname#*@}"
		hostname="${hostname%%/*}"
		hostname="${hostname%%:*}"
	elif [[ "$remote_url" == http* ]]; then
		# HTTPS: https://hostname/owner/repo.git
		hostname="${remote_url#*://}"
		hostname="${hostname%%/*}"
		hostname="${hostname%%:*}"
	fi

	# Known hostnames
	case "$hostname" in
	github.com | *.github.com)
		echo "github"
		return 0
		;;
	gitlab.com | *.gitlab.com)
		echo "gitlab"
		return 0
		;;
	esac

	# Probe for Gitea (GET /api/v1/version returns {"version":"..."})
	local base_url="https://${hostname}"
	local probe_result
	probe_result=$(curl -s --max-time 3 "${base_url}/api/v1/version" 2>/dev/null || echo "")
	if echo "$probe_result" | grep -q '"version"'; then
		echo "gitea"
		return 0
	fi

	# Probe for GitLab (GET /api/v4/version returns {"version":"...","revision":"..."})
	probe_result=$(curl -s --max-time 3 "${base_url}/api/v4/version" 2>/dev/null || echo "")
	if echo "$probe_result" | grep -q '"revision"'; then
		echo "gitlab"
		return 0
	fi

	# Default to github
	echo "github"
	return 0
}

# Extract base URL for API calls from git remote.
# For GitHub: not needed (uses gh CLI).
# For Gitea/GitLab: returns https://hostname
detect_platform_base_url() {
	local project_root="$1"

	local remote_url
	remote_url=$(git -C "$project_root" remote get-url origin 2>/dev/null || echo "")

	local hostname=""
	if [[ "$remote_url" == git@* ]]; then
		hostname="${remote_url#git@}"
		hostname="${hostname%%:*}"
	elif [[ "$remote_url" == ssh://* ]]; then
		hostname="${remote_url#ssh://}"
		hostname="${hostname#*@}"
		hostname="${hostname%%/*}"
		hostname="${hostname%%:*}"
	elif [[ "$remote_url" == http* ]]; then
		hostname="${remote_url#*://}"
		hostname="${hostname%%/*}"
		hostname="${hostname%%:*}"
	fi

	if [[ -n "$hostname" ]]; then
		echo "https://${hostname}"
	fi
	return 0
}

# Get API token for a platform.
# Checks platform-specific env vars, then falls back to credential helper.
# NEVER echoes the token to stdout in verbose/log output.
get_platform_token() {
	local platform="$1"

	case "$platform" in
	github)
		# gh CLI handles its own auth; return token for API fallback
		echo "${GH_TOKEN:-${GITHUB_TOKEN:-}}"
		;;
	gitea)
		echo "${GITEA_TOKEN:-}"
		;;
	gitlab)
		echo "${GITLAB_TOKEN:-}"
		;;
	esac
	return 0
}

# Verify platform CLI/credentials are available
verify_platform_auth() {
	local platform="$1"

	case "$platform" in
	github)
		verify_gh_cli
		return $?
		;;
	gitea)
		local token
		token=$(get_platform_token "gitea")
		if [[ -z "$token" ]]; then
			print_error "GITEA_TOKEN not set. Export GITEA_TOKEN=<your-token>"
			return 1
		fi
		if ! command -v curl &>/dev/null; then
			print_error "curl is required for Gitea API"
			return 1
		fi
		return 0
		;;
	gitlab)
		local token
		token=$(get_platform_token "gitlab")
		if [[ -z "$token" ]]; then
			print_error "GITLAB_TOKEN not set. Export GITLAB_TOKEN=<your-token>"
			return 1
		fi
		if ! command -v curl &>/dev/null; then
			print_error "curl is required for GitLab API"
			return 1
		fi
		return 0
		;;
	*)
		print_error "Unknown platform: $platform"
		return 1
		;;
	esac
}

# =============================================================================
# Platform API Adapters (t1120.3)
# =============================================================================
# Each adapter implements the same interface:
#   platform_create_issue <repo_slug> <title> <body> <labels_csv> [assignee]
#   platform_close_issue <repo_slug> <issue_number> <comment>
#   platform_edit_issue <repo_slug> <issue_number> <title> <body>
#   platform_list_issues <repo_slug> <state> <limit>
#   platform_add_labels <repo_slug> <issue_number> <labels_csv>
#   platform_create_label <repo_slug> <label_name> <color> <description>
#   platform_view_issue <repo_slug> <issue_number>

# --- GitHub Adapter (uses gh CLI) ---

github_create_issue() {
	local repo_slug="$1" title="$2" body="$3" labels="$4" assignee="${5:-}"
	local -a args=("issue" "create" "--repo" "$repo_slug" "--title" "$title" "--body" "$body")
	if [[ -n "$labels" ]]; then
		args+=("--label" "$labels")
	fi
	if [[ -n "$assignee" ]]; then
		args+=("--assignee" "$assignee")
	fi
	gh "${args[@]}" 2>/dev/null || echo ""
	return 0
}

github_close_issue() {
	local repo_slug="$1" issue_number="$2" comment="$3"
	gh issue close "$issue_number" --repo "$repo_slug" --comment "$comment" 2>/dev/null
	return $?
}

github_edit_issue() {
	local repo_slug="$1" issue_number="$2" title="$3" body="$4"
	gh issue edit "$issue_number" --repo "$repo_slug" --title "$title" --body "$body" 2>/dev/null
	return $?
}

github_list_issues() {
	local repo_slug="$1" state="$2" limit="$3"
	gh issue list --repo "$repo_slug" --state "$state" --limit "$limit" \
		--json number,title,assignees,state 2>/dev/null || echo "[]"
	return 0
}

github_add_labels() {
	local repo_slug="$1" issue_number="$2" labels="$3"
	local -a label_args=()
	local IFS=','
	for lbl in $labels; do
		[[ -n "$lbl" ]] && label_args+=("--add-label" "$lbl")
	done
	unset IFS
	if [[ ${#label_args[@]} -gt 0 ]]; then
		gh issue edit "$issue_number" --repo "$repo_slug" "${label_args[@]}" 2>/dev/null || true
	fi
	return 0
}

github_remove_labels() {
	local repo_slug="$1" issue_number="$2" labels="$3"
	local -a label_args=()
	local IFS=','
	for lbl in $labels; do
		[[ -n "$lbl" ]] && label_args+=("--remove-label" "$lbl")
	done
	unset IFS
	if [[ ${#label_args[@]} -gt 0 ]]; then
		gh issue edit "$issue_number" --repo "$repo_slug" "${label_args[@]}" 2>/dev/null || true
	fi
	return 0
}

github_create_label() {
	local repo_slug="$1" label_name="$2" color="$3" description="$4"
	gh label create "$label_name" --repo "$repo_slug" --color "$color" \
		--description "$description" --force 2>/dev/null || true
	return 0
}

github_view_issue() {
	local repo_slug="$1" issue_number="$2"
	gh issue view "$issue_number" --repo "$repo_slug" --json number,title,state,assignees 2>/dev/null || echo "{}"
	return 0
}

github_find_issue_by_title() {
	local repo_slug="$1" title_prefix="$2" state="${3:-all}" limit="${4:-50}"
	gh issue list --repo "$repo_slug" --state "$state" --limit "$limit" \
		--json number,title --jq "[.[] | select(.title | startswith(\"${title_prefix}\"))][0].number" 2>/dev/null || echo ""
	return 0
}

# Find a merged PR by task ID in title (GitHub-specific, uses gh CLI)
# Returns "number|url" on stdout, empty if not found.
github_find_merged_pr_by_task() {
	local repo_slug="$1" task_id="$2"
	local pr_json
	pr_json=$(gh pr list --repo "$repo_slug" --state merged \
		--search "$task_id in:title" --limit 1 --json number,url || echo "[]")
	local pr_data
	pr_data=$(echo "$pr_json" | jq -r '.[0] | select(. != null) | "\(.number)|\(.url)"' || echo "")
	if [[ -n "$pr_data" ]]; then
		echo "$pr_data"
	fi
	return 0
}

# --- Gitea Adapter (uses curl + REST API v1) ---
# t1120.2: Hardened adapter with HTTP error checking, label ID caching,
# pagination for search, and proper state normalization.

# Low-level Gitea API caller with HTTP status code checking.
# Outputs response body on stdout. Returns non-zero on HTTP errors (4xx/5xx).
# Arguments:
#   $1 - HTTP method (GET, POST, PATCH, DELETE, PUT)
#   $2 - API endpoint (relative to /api/v1/)
#   $3 - JSON request body (optional)
gitea_api() {
	local method="$1" endpoint="$2" data="${3:-}"
	local base_url="$_PLATFORM_BASE_URL"
	local token
	token=$(get_platform_token "gitea")
	local -a curl_args=("-s" "--max-time" "30" "-w" "\n%{http_code}" "-H" "Authorization: token ${token}" "-H" "Content-Type: application/json")
	if [[ "$method" != "GET" ]]; then
		curl_args+=("-X" "$method")
	fi
	if [[ -n "$data" ]]; then
		curl_args+=("-d" "$data")
	fi
	local raw_output
	raw_output=$(curl "${curl_args[@]}" "${base_url}/api/v1/${endpoint}")
	# Split response body from HTTP status code (last line)
	local http_code
	http_code=$(echo "$raw_output" | tail -n 1)
	local response_body
	response_body=$(echo "$raw_output" | sed '$d')
	# Check for HTTP errors
	case "$http_code" in
	2[0-9][0-9])
		# 2xx success — output the body
		echo "$response_body"
		return 0
		;;
	*)
		# Non-2xx — log and return error
		log_verbose "gitea_api: HTTP $http_code on $method /api/v1/$endpoint"
		echo "$response_body"
		return 1
		;;
	esac
}

# Resolve comma-separated label names to Gitea label IDs in a single API call.
# Fetches the repo's label list once and matches all names against it.
# Outputs comma-separated label IDs on stdout (e.g. "1,5,12"), empty if none found.
# Arguments:
#   $1 - owner
#   $2 - repo
#   $3 - labels (comma-separated names)
_gitea_resolve_label_ids() {
	local owner="$1" repo="$2" labels="$3"
	[[ -z "$labels" ]] && return 0
	# Fetch all repo labels in one API call
	local all_labels
	all_labels=$(gitea_api "GET" "repos/${owner}/${repo}/labels" 2>/dev/null || echo "[]")
	# Resolve each name to its ID using jq
	local label_ids=""
	local _saved_ifs="$IFS"
	IFS=','
	for lbl in $labels; do
		[[ -z "$lbl" ]] && continue
		local label_id
		label_id=$(echo "$all_labels" | jq -r --arg name "$lbl" '.[] | select(.name == $name) | .id' 2>/dev/null || echo "")
		if [[ -n "$label_id" ]]; then
			label_ids="${label_ids:+${label_ids},}${label_id}"
		fi
	done
	IFS="$_saved_ifs"
	echo "$label_ids"
	return 0
}

gitea_create_issue() {
	local repo_slug="$1" title="$2" body="$3" labels="$4" assignee="${5:-}"
	# Gitea expects owner/repo in the URL path
	local owner="${repo_slug%%/*}"
	local repo="${repo_slug#*/}"

	# Resolve label names to IDs in a single API call (Gitea requires label IDs)
	local label_ids_json="[]"
	if [[ -n "$labels" ]]; then
		local label_ids
		label_ids=$(_gitea_resolve_label_ids "$owner" "$repo" "$labels")
		if [[ -n "$label_ids" ]]; then
			label_ids_json="[${label_ids}]"
		fi
	fi

	local assignees_json="null"
	if [[ -n "$assignee" ]]; then
		assignees_json="[\"${assignee}\"]"
	fi

	local payload
	payload=$(jq -n \
		--arg title "$title" \
		--arg body "$body" \
		--argjson labels "$label_ids_json" \
		--argjson assignees "${assignees_json}" \
		'{title: $title, body: $body, labels: $labels, assignees: $assignees}')

	local response
	response=$(gitea_api "POST" "repos/${owner}/${repo}/issues" "$payload")
	# Return the issue URL (similar to gh output)
	local issue_number
	issue_number=$(echo "$response" | jq -r '.number // empty' 2>/dev/null || echo "")
	if [[ -n "$issue_number" ]]; then
		echo "${_PLATFORM_BASE_URL}/${repo_slug}/issues/${issue_number}"
	fi
	return 0
}

gitea_close_issue() {
	local repo_slug="$1" issue_number="$2" comment="$3"
	local owner="${repo_slug%%/*}"
	local repo="${repo_slug#*/}"

	# Add closing comment
	if [[ -n "$comment" ]]; then
		local comment_payload
		comment_payload=$(jq -n --arg body "$comment" '{body: $body}')
		gitea_api "POST" "repos/${owner}/${repo}/issues/${issue_number}/comments" "$comment_payload" >/dev/null
	fi

	# Close the issue
	local close_payload='{"state":"closed"}'
	gitea_api "PATCH" "repos/${owner}/${repo}/issues/${issue_number}" "$close_payload" >/dev/null
	return $?
}

gitea_edit_issue() {
	local repo_slug="$1" issue_number="$2" title="$3" body="$4"
	local owner="${repo_slug%%/*}"
	local repo="${repo_slug#*/}"
	local payload
	payload=$(jq -n --arg title "$title" --arg body "$body" '{title: $title, body: $body}')
	gitea_api "PATCH" "repos/${owner}/${repo}/issues/${issue_number}" "$payload" >/dev/null
	return $?
}

# List issues with normalized JSON output.
# Handles Gitea's state parameter: "open", "closed", or "all".
# Note: Gitea API does not support state=all directly — we omit the state
# parameter to get all issues (Gitea defaults to returning all states when
# the state parameter is absent).
# Arguments:
#   $1 - repo_slug (owner/repo)
#   $2 - state (open|closed|all)
#   $3 - limit (max results)
gitea_list_issues() {
	local repo_slug="$1" state="$2" limit="$3"
	local owner="${repo_slug%%/*}"
	local repo="${repo_slug#*/}"
	# Build query params — omit state for "all" (Gitea returns all states by default)
	local state_param=""
	if [[ "$state" != "all" ]]; then
		state_param="&state=${state}"
	fi
	local response
	response=$(gitea_api "GET" "repos/${owner}/${repo}/issues?limit=${limit}&type=issues${state_param}")
	# Normalize to same JSON shape as GitHub: [{number, title, assignees: [{login}], state}]
	echo "$response" | jq '[.[] | {number: .number, title: .title, state: .state, assignees: [.assignees[]? | {login: .login}]}]' 2>/dev/null || echo "[]"
	return 0
}

gitea_add_labels() {
	local repo_slug="$1" issue_number="$2" labels="$3"
	local owner="${repo_slug%%/*}"
	local repo="${repo_slug#*/}"
	# Resolve all label names to IDs in a single API call
	local label_ids
	label_ids=$(_gitea_resolve_label_ids "$owner" "$repo" "$labels")
	if [[ -n "$label_ids" ]]; then
		gitea_api "POST" "repos/${owner}/${repo}/issues/${issue_number}/labels" "{\"labels\":[${label_ids}]}" >/dev/null
	fi
	return 0
}

gitea_remove_labels() {
	local repo_slug="$1" issue_number="$2" labels="$3"
	local owner="${repo_slug%%/*}"
	local repo="${repo_slug#*/}"
	# Fetch all labels once, then delete each matching ID
	local all_labels
	all_labels=$(gitea_api "GET" "repos/${owner}/${repo}/labels" 2>/dev/null || echo "[]")
	local _saved_ifs="$IFS"
	IFS=','
	for lbl in $labels; do
		[[ -z "$lbl" ]] && continue
		local label_id
		label_id=$(echo "$all_labels" | jq -r --arg name "$lbl" '.[] | select(.name == $name) | .id' 2>/dev/null || echo "")
		if [[ -n "$label_id" ]]; then
			gitea_api "DELETE" "repos/${owner}/${repo}/issues/${issue_number}/labels/${label_id}" >/dev/null 2>/dev/null || true
		fi
	done
	IFS="$_saved_ifs"
	return 0
}

gitea_create_label() {
	local repo_slug="$1" label_name="$2" color="$3" description="$4"
	local owner="${repo_slug%%/*}"
	local repo="${repo_slug#*/}"
	# Fetch all labels once to check existence
	local all_labels
	all_labels=$(gitea_api "GET" "repos/${owner}/${repo}/labels" 2>/dev/null || echo "[]")
	local existing
	existing=$(echo "$all_labels" | jq -r --arg name "$label_name" '.[] | select(.name == $name) | .id' 2>/dev/null || echo "")
	local payload
	payload=$(jq -n --arg name "$label_name" --arg color "#${color}" --arg desc "$description" \
		'{name: $name, color: $color, description: $desc}')
	if [[ -n "$existing" ]]; then
		# Update existing label
		gitea_api "PATCH" "repos/${owner}/${repo}/labels/${existing}" "$payload" >/dev/null
	else
		# Create new label
		gitea_api "POST" "repos/${owner}/${repo}/labels" "$payload" >/dev/null
	fi
	return 0
}

gitea_view_issue() {
	local repo_slug="$1" issue_number="$2"
	local owner="${repo_slug%%/*}"
	local repo="${repo_slug#*/}"
	local response
	response=$(gitea_api "GET" "repos/${owner}/${repo}/issues/${issue_number}")
	echo "$response" | jq '{number: .number, title: .title, state: .state, assignees: [.assignees[]? | {login: .login}]}' 2>/dev/null || echo "{}"
	return 0
}

# Search for an issue by title prefix with pagination support.
# Gitea lacks a dedicated search-by-title API, so we list issues and filter
# client-side. Paginates through results to avoid missing matches beyond
# the first page.
# Arguments:
#   $1 - repo_slug (owner/repo)
#   $2 - title_prefix (e.g. "t1120:")
#   $3 - state (open|closed|all, default: all)
#   $4 - limit per page (default: 50)
# Returns: issue number on stdout, empty if not found.
gitea_find_issue_by_title() {
	local repo_slug="$1" title_prefix="$2" state="${3:-all}" limit="${4:-50}"
	local owner="${repo_slug%%/*}"
	local repo="${repo_slug#*/}"
	local state_param=""
	if [[ "$state" != "all" ]]; then
		state_param="&state=${state}"
	fi
	local page=1
	while true; do
		local response
		response=$(gitea_api "GET" "repos/${owner}/${repo}/issues?limit=${limit}&type=issues&page=${page}${state_param}")
		local count
		count=$(echo "$response" | jq 'length' 2>/dev/null || echo "0")
		if [[ "$count" -eq 0 ]]; then
			break
		fi
		local match
		match=$(echo "$response" | jq -r --arg prefix "$title_prefix" \
			'[.[] | select(.title | startswith($prefix))][0].number // empty' 2>/dev/null || echo "")
		if [[ -n "$match" ]]; then
			echo "$match"
			return 0
		fi
		# Stop if we got fewer results than the limit (last page)
		if [[ "$count" -lt "$limit" ]]; then
			break
		fi
		page=$((page + 1))
	done
	echo ""
	return 0
}

# Search issues by query string using Gitea's search endpoint.
# Uses GET /repos/{owner}/{repo}/issues?q={query} for server-side filtering.
# Returns normalized JSON array on stdout (same shape as gitea_list_issues).
# Arguments:
#   $1 - repo_slug (owner/repo)
#   $2 - query string
#   $3 - state (open|closed|all, default: open)
#   $4 - limit (default: 50)
gitea_search_issues() {
	local repo_slug="$1" query="$2" state="${3:-open}" limit="${4:-50}"
	local owner="${repo_slug%%/*}"
	local repo="${repo_slug#*/}"
	local state_param=""
	if [[ "$state" != "all" ]]; then
		state_param="&state=${state}"
	fi
	# URL-encode the query for safe inclusion in the URL
	local encoded_query
	encoded_query=$(printf '%s' "$query" | jq -sRr @uri)
	local response
	response=$(gitea_api "GET" "repos/${owner}/${repo}/issues?q=${encoded_query}&limit=${limit}&type=issues${state_param}")
	echo "$response" | jq '[.[] | {number: .number, title: .title, state: .state, assignees: [.assignees[]? | {login: .login}]}]' 2>/dev/null || echo "[]"
	return 0
}

# Find a merged PR by task ID in title (Gitea REST API v1)
# Returns "number|url" on stdout, empty if not found.
# Paginates through closed PRs until a match is found or results are exhausted.
gitea_find_merged_pr_by_task() {
	local repo_slug="$1" task_id="$2"
	local owner="${repo_slug%%/*}"
	local repo="${repo_slug#*/}"
	local page=1
	local limit=50
	# Gitea: list closed PRs (merged PRs have state=closed and merged=true)
	# Note: /pulls endpoint does not support type=pulls (that param is for /issues)
	while true; do
		local response
		response=$(gitea_api "GET" "repos/${owner}/${repo}/pulls?state=closed&limit=${limit}&page=${page}")
		# Stop if response is empty array
		local count
		count=$(echo "$response" | jq 'length' 2>/dev/null || echo "0")
		if [[ "$count" -eq 0 ]]; then
			break
		fi
		local pr_data
		pr_data=$(echo "$response" | jq -r --arg tid "${task_id}:" \
			'.[] | select(.title | startswith($tid)) | select(.merged == true) | "\(.number)|\(.html_url)"' |
			head -n 1 || echo "")
		if [[ -n "$pr_data" ]]; then
			echo "$pr_data"
			return 0
		fi
		# Stop if we got fewer results than the limit (last page)
		if [[ "$count" -lt "$limit" ]]; then
			break
		fi
		page=$((page + 1))
	done
	return 0
}

# --- GitLab Adapter (uses curl + REST API v4) ---

gitlab_api() {
	local method="$1" endpoint="$2" data="${3:-}"
	local base_url="$_PLATFORM_BASE_URL"
	local token
	token=$(get_platform_token "gitlab")
	local -a curl_args=("-s" "--max-time" "30" "-H" "PRIVATE-TOKEN: ${token}" "-H" "Content-Type: application/json")
	if [[ "$method" != "GET" ]]; then
		curl_args+=("-X" "$method")
	fi
	if [[ -n "$data" ]]; then
		curl_args+=("-d" "$data")
	fi
	curl "${curl_args[@]}" "${base_url}/api/v4/${endpoint}"
	return 0
}

# GitLab uses URL-encoded project path instead of owner/repo
_gitlab_project_path() {
	local repo_slug="$1"
	# URL-encode the slash: owner/repo -> owner%2Frepo
	echo "${repo_slug/\//%2F}"
	return 0
}

gitlab_create_issue() {
	local repo_slug="$1" title="$2" body="$3" labels="$4" assignee="${5:-}"
	local project_path
	project_path=$(_gitlab_project_path "$repo_slug")

	local payload
	payload=$(jq -n \
		--arg title "$title" \
		--arg description "$body" \
		--arg labels "$labels" \
		'{title: $title, description: $description, labels: $labels}')

	local response
	response=$(gitlab_api "POST" "projects/${project_path}/issues" "$payload")
	local issue_iid
	issue_iid=$(echo "$response" | jq -r '.iid // empty' 2>/dev/null || echo "")
	if [[ -n "$issue_iid" ]]; then
		echo "${_PLATFORM_BASE_URL}/${repo_slug}/-/issues/${issue_iid}"
	fi
	return 0
}

gitlab_close_issue() {
	local repo_slug="$1" issue_iid="$2" comment="$3"
	local project_path
	project_path=$(_gitlab_project_path "$repo_slug")

	# Add closing comment (note)
	if [[ -n "$comment" ]]; then
		local note_payload
		note_payload=$(jq -n --arg body "$comment" '{body: $body}')
		gitlab_api "POST" "projects/${project_path}/issues/${issue_iid}/notes" "$note_payload" >/dev/null
	fi

	# Close the issue
	gitlab_api "PUT" "projects/${project_path}/issues/${issue_iid}" '{"state_event":"close"}' >/dev/null
	return $?
}

gitlab_edit_issue() {
	local repo_slug="$1" issue_iid="$2" title="$3" body="$4"
	local project_path
	project_path=$(_gitlab_project_path "$repo_slug")
	local payload
	payload=$(jq -n --arg title "$title" --arg description "$body" '{title: $title, description: $description}')
	gitlab_api "PUT" "projects/${project_path}/issues/${issue_iid}" "$payload" >/dev/null
	return $?
}

gitlab_list_issues() {
	local repo_slug="$1" state="$2" limit="$3"
	local project_path
	project_path=$(_gitlab_project_path "$repo_slug")
	# GitLab uses "opened"/"closed"/"all" for state
	local gl_state="$state"
	[[ "$state" == "open" ]] && gl_state="opened"
	local response
	response=$(gitlab_api "GET" "projects/${project_path}/issues?state=${gl_state}&per_page=${limit}")
	# Normalize to same JSON shape: [{number (=iid), title, assignees: [{login (=username)}], state}]
	echo "$response" | jq '[.[] | {number: .iid, title: .title, state: .state, assignees: [.assignees[]? | {login: .username}]}]' 2>/dev/null || echo "[]"
	return 0
}

gitlab_add_labels() {
	local repo_slug="$1" issue_iid="$2" labels="$3"
	local project_path
	project_path=$(_gitlab_project_path "$repo_slug")
	# GitLab: add_labels is a comma-separated string
	gitlab_api "PUT" "projects/${project_path}/issues/${issue_iid}" "{\"add_labels\":\"${labels}\"}" >/dev/null
	return 0
}

gitlab_remove_labels() {
	local repo_slug="$1" issue_iid="$2" labels="$3"
	local project_path
	project_path=$(_gitlab_project_path "$repo_slug")
	gitlab_api "PUT" "projects/${project_path}/issues/${issue_iid}" "{\"remove_labels\":\"${labels}\"}" >/dev/null
	return 0
}

gitlab_create_label() {
	local repo_slug="$1" label_name="$2" color="$3" description="$4"
	local project_path
	project_path=$(_gitlab_project_path "$repo_slug")
	local payload
	payload=$(jq -n --arg name "$label_name" --arg color "#${color}" --arg desc "$description" \
		'{name: $name, color: $color, description: $desc}')
	# Try create; if 409 conflict (exists), update
	local response
	response=$(gitlab_api "POST" "projects/${project_path}/labels" "$payload")
	if echo "$response" | grep -q '"message".*already_exists\|Label already exists'; then
		# URL-encode label name for the endpoint
		local encoded_name
		encoded_name=$(printf '%s' "$label_name" | jq -sRr @uri)
		gitlab_api "PUT" "projects/${project_path}/labels/${encoded_name}" "$payload" >/dev/null
	fi
	return 0
}

gitlab_view_issue() {
	local repo_slug="$1" issue_iid="$2"
	local project_path
	project_path=$(_gitlab_project_path "$repo_slug")
	local response
	response=$(gitlab_api "GET" "projects/${project_path}/issues/${issue_iid}")
	echo "$response" | jq '{number: .iid, title: .title, state: .state, assignees: [.assignees[]? | {login: .username}]}' 2>/dev/null || echo "{}"
	return 0
}

gitlab_find_issue_by_title() {
	local repo_slug="$1" title_prefix="$2" state="${3:-all}" limit="${4:-50}"
	local project_path
	project_path=$(_gitlab_project_path "$repo_slug")
	local gl_state="$state"
	[[ "$state" == "open" ]] && gl_state="opened"
	[[ "$state" == "all" ]] && gl_state=""
	local state_param=""
	[[ -n "$gl_state" ]] && state_param="&state=${gl_state}"
	# GitLab supports search parameter for title filtering
	local encoded_prefix
	encoded_prefix=$(printf '%s' "$title_prefix" | jq -sRr @uri)
	local response
	response=$(gitlab_api "GET" "projects/${project_path}/issues?search=${encoded_prefix}&per_page=${limit}${state_param}")
	echo "$response" | jq -r "[.[] | select(.title | startswith(\"${title_prefix}\"))][0].iid // empty" 2>/dev/null || echo ""
	return 0
}

# Find a merged MR by task ID in title (GitLab REST API v4)
# Returns "number|url" on stdout, empty if not found.
gitlab_find_merged_pr_by_task() {
	local repo_slug="$1" task_id="$2"
	local project_path
	project_path=$(_gitlab_project_path "$repo_slug")
	local encoded_task
	encoded_task=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.stdin.read().strip()))' <<<"$task_id")
	local response
	response=$(gitlab_api "GET" "projects/${project_path}/merge_requests?state=merged&search=${encoded_task}&per_page=10")
	local mr_data
	mr_data=$(echo "$response" | jq -r --arg tid "${task_id}:" \
		'.[] | select(.title | startswith($tid)) | "\(.iid)|\(.web_url)"' |
		head -n 1 || echo "")
	if [[ -n "$mr_data" ]]; then
		echo "$mr_data"
	fi
	return 0
}

# =============================================================================
# Platform Dispatch Layer (t1120.3)
# =============================================================================
# Routes calls to the correct platform adapter based on $_DETECTED_PLATFORM.
# All functions follow the same interface as the platform-specific adapters.

# Global state set during init
_DETECTED_PLATFORM=""
_PLATFORM_BASE_URL=""

# Initialize platform detection for a project root.
# Must be called before any platform_* dispatch function.
init_platform() {
	local project_root="$1"
	_DETECTED_PLATFORM=$(detect_platform "$project_root")
	_PLATFORM_BASE_URL=$(detect_platform_base_url "$project_root")
	log_verbose "Detected platform: $_DETECTED_PLATFORM (base: ${_PLATFORM_BASE_URL:-n/a})"
	return 0
}

platform_create_issue() {
	case "$_DETECTED_PLATFORM" in
	github) github_create_issue "$@" ;;
	gitea) gitea_create_issue "$@" ;;
	gitlab) gitlab_create_issue "$@" ;;
	*)
		print_error "Unsupported platform: $_DETECTED_PLATFORM"
		return 1
		;;
	esac
}

platform_close_issue() {
	case "$_DETECTED_PLATFORM" in
	github) github_close_issue "$@" ;;
	gitea) gitea_close_issue "$@" ;;
	gitlab) gitlab_close_issue "$@" ;;
	*)
		print_error "Unsupported platform: $_DETECTED_PLATFORM"
		return 1
		;;
	esac
}

platform_edit_issue() {
	case "$_DETECTED_PLATFORM" in
	github) github_edit_issue "$@" ;;
	gitea) gitea_edit_issue "$@" ;;
	gitlab) gitlab_edit_issue "$@" ;;
	*)
		print_error "Unsupported platform: $_DETECTED_PLATFORM"
		return 1
		;;
	esac
}

platform_list_issues() {
	case "$_DETECTED_PLATFORM" in
	github) github_list_issues "$@" ;;
	gitea) gitea_list_issues "$@" ;;
	gitlab) gitlab_list_issues "$@" ;;
	*)
		print_error "Unsupported platform: $_DETECTED_PLATFORM"
		return 1
		;;
	esac
}

platform_add_labels() {
	case "$_DETECTED_PLATFORM" in
	github) github_add_labels "$@" ;;
	gitea) gitea_add_labels "$@" ;;
	gitlab) gitlab_add_labels "$@" ;;
	*)
		print_error "Unsupported platform: $_DETECTED_PLATFORM"
		return 1
		;;
	esac
}

platform_remove_labels() {
	case "$_DETECTED_PLATFORM" in
	github) github_remove_labels "$@" ;;
	gitea) gitea_remove_labels "$@" ;;
	gitlab) gitlab_remove_labels "$@" ;;
	*)
		print_error "Unsupported platform: $_DETECTED_PLATFORM"
		return 1
		;;
	esac
}

platform_create_label() {
	case "$_DETECTED_PLATFORM" in
	github) github_create_label "$@" ;;
	gitea) gitea_create_label "$@" ;;
	gitlab) gitlab_create_label "$@" ;;
	*)
		print_error "Unsupported platform: $_DETECTED_PLATFORM"
		return 1
		;;
	esac
}

platform_view_issue() {
	case "$_DETECTED_PLATFORM" in
	github) github_view_issue "$@" ;;
	gitea) gitea_view_issue "$@" ;;
	gitlab) gitlab_view_issue "$@" ;;
	*)
		print_error "Unsupported platform: $_DETECTED_PLATFORM"
		return 1
		;;
	esac
}

platform_find_issue_by_title() {
	case "$_DETECTED_PLATFORM" in
	github) github_find_issue_by_title "$@" ;;
	gitea) gitea_find_issue_by_title "$@" ;;
	gitlab) gitlab_find_issue_by_title "$@" ;;
	*)
		print_error "Unsupported platform: $_DETECTED_PLATFORM"
		return 1
		;;
	esac
}

# Find a merged PR/MR by task ID in title (platform-agnostic).
# Returns "number|url" on stdout, empty if not found.
# $1: repo_slug  $2: task_id
platform_find_merged_pr_by_task() {
	case "$_DETECTED_PLATFORM" in
	github) github_find_merged_pr_by_task "$@" ;;
	gitea) gitea_find_merged_pr_by_task "$@" ;;
	gitlab) gitlab_find_merged_pr_by_task "$@" ;;
	*)
		return 0
		;;
	esac
}

# Verify gh CLI is available and authenticated
verify_gh_cli() {
	if ! command -v gh &>/dev/null; then
		print_error "gh CLI not installed. Install with: brew install gh"
		return 1
	fi
	# Accept GH_TOKEN or GITHUB_TOKEN env vars (used in GitHub Actions)
	# gh auth status checks the credential store but doesn't recognize env tokens
	if [[ -n "${GH_TOKEN:-}" || -n "${GITHUB_TOKEN:-}" ]]; then
		return 0
	fi
	if ! gh auth status &>/dev/null 2>&1; then
		print_error "gh CLI not authenticated. Run: gh auth login"
		return 1
	fi
	return 0
}

# =============================================================================
# TODO.md Parser
# =============================================================================
# parse_task_line, extract_task_block, extract_subtasks, extract_notes
# — sourced from issue-sync-lib.sh

# =============================================================================
# PLANS.md Parser
# =============================================================================
# extract_plan_section, _extract_plan_subsection, extract_plan_purpose,
# extract_plan_decisions, extract_plan_progress, extract_plan_discoveries,
# find_plan_by_task_id, extract_plan_extra_sections
# — sourced from issue-sync-lib.sh

# =============================================================================
# PRD/Task File Lookup
# =============================================================================
# find_related_files, extract_file_summary — sourced from issue-sync-lib.sh

# =============================================================================
# Tag to Label Mapping
# =============================================================================
# map_tags_to_labels — sourced from issue-sync-lib.sh

# Ensure all labels in a comma-separated list exist on the repo (multi-platform).
# Creates missing labels with a neutral colour via platform adapter.
ensure_labels_exist() {
	local labels="$1"
	local repo_slug="$2"

	[[ -z "$labels" || -z "$repo_slug" ]] && return 0

	local label
	local _saved_ifs="$IFS"
	IFS=','
	for label in $labels; do
		[[ -z "$label" ]] && continue
		platform_create_label "$repo_slug" "$label" "EDEDED" "Auto-created from TODO.md tag"
	done
	IFS="$_saved_ifs"
	return 0
}

# =============================================================================
# Issue Body Composer
# =============================================================================
# compose_issue_body — sourced from issue-sync-lib.sh

# =============================================================================
# Commands
# =============================================================================

# Push: create issues from TODO.md tasks (multi-platform)
cmd_push() {
	local target_task="${1:-}"
	local project_root
	project_root=$(find_project_root) || return 1
	local repo_slug="${REPO_SLUG:-$(detect_repo_slug "$project_root")}"
	local todo_file="$project_root/TODO.md"

	init_platform "$project_root"
	verify_platform_auth "$_DETECTED_PLATFORM" || return 1

	# Collect tasks to process
	local tasks=()
	if [[ -n "$target_task" ]]; then
		tasks=("$target_task")
	else
		# Find all open tasks without GH refs (top-level and subtasks)
		while IFS= read -r line; do
			local tid
			tid=$(echo "$line" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1 || echo "")
			if [[ -n "$tid" ]] && ! echo "$line" | grep -qE 'ref:GH#[0-9]+'; then
				tasks+=("$tid")
			fi
		done < <(strip_code_fences <"$todo_file" | grep -E '^\s*- \[ \] t[0-9]+' || true)
	fi

	if [[ ${#tasks[@]} -eq 0 ]]; then
		print_info "No tasks to push (all have ref:GH# or none match)"
		return 0
	fi

	print_info "Processing ${#tasks[@]} task(s) for push to $repo_slug ($_DETECTED_PLATFORM)"

	# Ensure status:available label exists (t164 — label may not exist in new repos)
	platform_create_label "$repo_slug" "status:available" "0E8A16" "Task is available for claiming"

	local created=0
	local skipped=0
	for task_id in "${tasks[@]}"; do
		log_verbose "Processing $task_id..."

		# Cross-repo guard (t1235): verify this task belongs to the current repo.
		# The supervisor DB is authoritative for task-to-repo mapping. When the
		# supervisor calls cmd_push from the aidevops repo but TODO.md contains
		# tasks from other repos (cross-repo DB), we must skip those tasks —
		# their own repo's issue-sync run will handle them.
		local task_repo_slug=""
		task_repo_slug=$(_lookup_task_repo_slug "$task_id")
		if [[ -n "$task_repo_slug" && "$task_repo_slug" != "$repo_slug" ]]; then
			log_verbose "$task_id belongs to $task_repo_slug (not $repo_slug) — skipping cross-repo task"
			skipped=$((skipped + 1))
			continue
		fi

		# Check if issue already exists (platform-agnostic title search)
		local existing
		existing=$(platform_find_issue_by_title "$repo_slug" "${task_id}:" "all" 50)
		if [[ -n "$existing" && "$existing" != "null" ]]; then
			log_verbose "$task_id already has issue #$existing"
			# Add ref to TODO.md if missing
			add_gh_ref_to_todo "$task_id" "$existing" "$todo_file"
			skipped=$((skipped + 1))
			continue
		fi

		# Parse task for title and labels (match both top-level and indented subtasks)
		# (parse early so we can use description for duplicate check)
		local task_line
		task_line=$(grep -E "^\s*- \[.\] ${task_id} " "$todo_file" | head -1 || echo "")
		if [[ -z "$task_line" ]]; then
			print_warning "Task $task_id not found in TODO.md"
			continue
		fi

		local parsed
		parsed=$(parse_task_line "$task_line")
		local description
		description=$(echo "$parsed" | grep '^description=' | cut -d= -f2-)
		local tags
		tags=$(echo "$parsed" | grep '^tags=' | cut -d= -f2-)
		local assignee
		assignee=$(echo "$parsed" | grep '^assignee=' | cut -d= -f2-)

		# Split at em dash for concise title; full description goes in body
		local title
		if [[ "$description" == *" — "* ]]; then
			title="${task_id}: ${description%% — *}"
		elif [[ ${#description} -gt 80 ]]; then
			title="${task_id}: ${description:0:77}..."
		else
			title="${task_id}: ${description}"
		fi
		local labels
		labels=$(map_tags_to_labels "$tags")

		# t1324: AI-based semantic duplicate detection before creating
		# Only runs on GitHub (gh CLI required for issue listing)
		if [[ "$_DETECTED_PLATFORM" == "github" ]]; then
			local dup_issue_num
			if dup_issue_num=$(_ai_check_duplicate "$title" "$repo_slug" 2>/dev/null); then
				if [[ -n "$dup_issue_num" ]]; then
					print_info "$task_id: semantic duplicate of #$dup_issue_num — linking instead of creating"
					add_gh_ref_to_todo "$task_id" "$dup_issue_num" "$todo_file"
					skipped=$((skipped + 1))
					continue
				fi
			fi
		fi

		# Compose rich body
		local body
		body=$(compose_issue_body "$task_id" "$project_root")

		if [[ "$DRY_RUN" == "true" ]]; then
			print_info "[DRY-RUN] Would create: $title"
			if [[ -n "$labels" ]]; then
				print_info "  Labels: $labels"
			fi
			if [[ -n "$assignee" ]]; then
				print_info "  Assignee: $assignee"
			fi
			created=$((created + 1))
			continue
		fi

		# Ensure all tag-derived labels exist on the repo (t295)
		if [[ -n "$labels" ]]; then
			ensure_labels_exist "$labels" "$repo_slug"
		fi

		# Create the issue with appropriate status label (t164, t212)
		local status_label="status:available"
		if [[ -n "$assignee" ]]; then
			status_label="status:claimed"
			platform_create_label "$repo_slug" "status:claimed" "D93F0B" "Task is claimed by a worker"
		fi
		local all_labels="${labels:+${labels},}${status_label}"

		# Double-check: re-verify no issue was created by a concurrent workflow run
		# between our first check and now (t1142 — guards against race conditions)
		local existing_recheck
		existing_recheck=$(platform_find_issue_by_title "$repo_slug" "${task_id}:" "all" 50)
		if [[ -n "$existing_recheck" && "$existing_recheck" != "null" ]]; then
			log_verbose "$task_id issue created by concurrent run (#$existing_recheck) — skipping"
			add_gh_ref_to_todo "$task_id" "$existing_recheck" "$todo_file"
			skipped=$((skipped + 1))
			continue
		fi

		local issue_url
		issue_url=$(platform_create_issue "$repo_slug" "$title" "$body" "$all_labels" "$assignee")
		if [[ -z "$issue_url" ]]; then
			print_error "Failed to create issue for $task_id"
			continue
		fi

		local issue_number
		issue_number=$(echo "$issue_url" | grep -oE '[0-9]+$' || echo "")
		if [[ -n "$issue_number" ]]; then
			print_success "Created #$issue_number: $title"
			add_gh_ref_to_todo "$task_id" "$issue_number" "$todo_file"
			created=$((created + 1))
		fi
	done

	print_info "Push complete: $created created, $skipped skipped (already exist)"
	return 0
}

# Enrich: update existing issue bodies with full context (multi-platform)
cmd_enrich() {
	local target_task="${1:-}"
	local project_root
	project_root=$(find_project_root) || return 1
	local repo_slug="${REPO_SLUG:-$(detect_repo_slug "$project_root")}"
	local todo_file="$project_root/TODO.md"

	init_platform "$project_root"
	verify_platform_auth "$_DETECTED_PLATFORM" || return 1

	# Collect tasks to enrich
	local tasks=()
	if [[ -n "$target_task" ]]; then
		tasks=("$target_task")
	else
		# Find all open tasks WITH GH refs
		while IFS= read -r line; do
			local tid
			tid=$(echo "$line" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1 || echo "")
			if [[ -n "$tid" ]]; then
				tasks+=("$tid")
			fi
		done < <(strip_code_fences <"$todo_file" | grep -E '^\s*- \[ \] t[0-9]+.*ref:GH#[0-9]+' || true)
	fi

	if [[ ${#tasks[@]} -eq 0 ]]; then
		print_info "No tasks to enrich"
		return 0
	fi

	print_info "Enriching ${#tasks[@]} issue(s) in $repo_slug"

	local enriched=0
	for task_id in "${tasks[@]}"; do
		# Cross-repo guard (t1235)
		local task_repo_slug=""
		task_repo_slug=$(_lookup_task_repo_slug "$task_id")
		if [[ -n "$task_repo_slug" && "$task_repo_slug" != "$repo_slug" ]]; then
			log_verbose "$task_id belongs to $task_repo_slug, not $repo_slug — skipping enrich"
			continue
		fi

		# Find the issue number (match both top-level and indented subtasks)
		local task_line
		task_line=$(grep -E "^\s*- \[.\] ${task_id} " "$todo_file" | head -1 || echo "")
		local issue_number
		issue_number=$(echo "$task_line" | grep -oE 'ref:GH#[0-9]+' | head -1 | sed 's/ref:GH#//' || echo "")

		if [[ -z "$issue_number" ]]; then
			# Try searching by title prefix (platform-agnostic)
			issue_number=$(platform_find_issue_by_title "$repo_slug" "${task_id}:" "all" 50)
		fi

		if [[ -z "$issue_number" || "$issue_number" == "null" ]]; then
			print_warning "$task_id: no matching issue found on $_DETECTED_PLATFORM (skipping enrich)"
			continue
		fi

		# Parse tags and map to labels (t295)
		local parsed
		parsed=$(parse_task_line "$task_line")
		local description
		description=$(echo "$parsed" | grep '^description=' | cut -d= -f2-)
		local tags
		tags=$(echo "$parsed" | grep '^tags=' | cut -d= -f2-)
		local labels
		labels=$(map_tags_to_labels "$tags")

		# Build concise title (same logic as create)
		local title
		if [[ "$description" == *" — "* ]]; then
			title="${task_id}: ${description%% — *}"
		elif [[ ${#description} -gt 80 ]]; then
			title="${task_id}: ${description:0:77}..."
		else
			title="${task_id}: ${description}"
		fi

		# Compose rich body
		local body
		body=$(compose_issue_body "$task_id" "$project_root")

		if [[ "$DRY_RUN" == "true" ]]; then
			print_info "[DRY-RUN] Would enrich #$issue_number ($task_id)"
			if [[ -n "$labels" ]]; then
				print_info "  Labels: $labels"
			fi
			enriched=$((enriched + 1))
			continue
		fi

		# Ensure labels exist and sync them to the issue (t295, multi-platform)
		if [[ -n "$labels" ]]; then
			ensure_labels_exist "$labels" "$repo_slug"
			platform_add_labels "$repo_slug" "$issue_number" "$labels"
		fi

		# Update the issue title and body (multi-platform)
		if platform_edit_issue "$repo_slug" "$issue_number" "$title" "$body"; then
			print_success "Enriched #$issue_number ($task_id)"
			enriched=$((enriched + 1))
		else
			print_error "Failed to enrich #$issue_number ($task_id)"
		fi
	done

	print_info "Enrich complete: $enriched updated"
	return 0
}

# Pull: sync issue refs back to TODO.md (multi-platform)
# Detects orphan issues (issues with t-number titles but no TODO.md entry),
# adds ref:GH#NNN to tasks missing it, and syncs assignees to TODO.md.
cmd_pull() {
	local project_root
	project_root=$(find_project_root) || return 1
	local repo_slug="${REPO_SLUG:-$(detect_repo_slug "$project_root")}"
	local todo_file="$project_root/TODO.md"

	init_platform "$project_root"
	verify_platform_auth "$_DETECTED_PLATFORM" || return 1

	print_info "Pulling issue refs from $_DETECTED_PLATFORM ($repo_slug) to TODO.md..."

	# Get all open issues with t-number prefixes (include assignees for assignee: sync)
	local issues_json
	issues_json=$(platform_list_issues "$repo_slug" "open" 200)

	local synced=0
	local orphan_open=0
	local orphan_open_list=""
	while IFS= read -r issue_line; do
		local issue_number
		issue_number=$(echo "$issue_line" | jq -r '.number' 2>/dev/null || echo "")
		local issue_title
		issue_title=$(echo "$issue_line" | jq -r '.title' 2>/dev/null || echo "")

		# Extract task ID from issue title
		local task_id
		task_id=$(echo "$issue_title" | grep -oE '^t[0-9]+(\.[0-9]+)*' || echo "")
		if [[ -z "$task_id" ]]; then
			continue
		fi

		# Check if TODO.md already has this ref (match both top-level and indented subtasks)
		if grep -qE "^\s*- \[.\] ${task_id} .*ref:GH#${issue_number}" "$todo_file" 2>/dev/null; then
			continue
		fi

		# Check if task exists in TODO.md (any checkbox state, any indent level)
		if ! grep -qE "^\s*- \[.\] ${task_id} " "$todo_file" 2>/dev/null; then
			# Orphan: platform issue exists but no TODO.md entry
			print_warning "ORPHAN: #$issue_number ($task_id: $issue_title) — no TODO.md entry"
			orphan_open=$((orphan_open + 1))
			orphan_open_list="${orphan_open_list:+$orphan_open_list, }#$issue_number ($task_id)"
			continue
		fi

		if [[ "$DRY_RUN" == "true" ]]; then
			print_info "[DRY-RUN] Would add ref:GH#$issue_number to $task_id"
			synced=$((synced + 1))
			continue
		fi

		add_gh_ref_to_todo "$task_id" "$issue_number" "$todo_file"
		print_success "Added ref:GH#$issue_number to $task_id"
		synced=$((synced + 1))
	done < <(echo "$issues_json" | jq -c '.[]' 2>/dev/null || true)

	# Also check closed issues for completed tasks (multi-platform)
	local closed_json
	closed_json=$(platform_list_issues "$repo_slug" "closed" 200)

	local orphan_closed=0
	while IFS= read -r issue_line; do
		local issue_number
		issue_number=$(echo "$issue_line" | jq -r '.number' 2>/dev/null || echo "")
		local issue_title
		issue_title=$(echo "$issue_line" | jq -r '.title' 2>/dev/null || echo "")

		local task_id
		task_id=$(echo "$issue_title" | grep -oE '^t[0-9]+(\.[0-9]+)*' || echo "")
		if [[ -z "$task_id" ]]; then
			continue
		fi

		if grep -qE "^\s*- \[.\] ${task_id} .*ref:GH#${issue_number}" "$todo_file" 2>/dev/null; then
			continue
		fi

		if ! grep -qE "^\s*- \[.\] ${task_id} " "$todo_file" 2>/dev/null; then
			log_verbose "ORPHAN (closed): #$issue_number ($task_id) — no TODO.md entry"
			orphan_closed=$((orphan_closed + 1))
			continue
		fi

		if [[ "$DRY_RUN" == "true" ]]; then
			print_info "[DRY-RUN] Would add ref:GH#$issue_number to $task_id"
			synced=$((synced + 1))
			continue
		fi

		add_gh_ref_to_todo "$task_id" "$issue_number" "$todo_file"
		print_success "Added ref:GH#$issue_number to $task_id (closed issue)"
		synced=$((synced + 1))
	done < <(echo "$closed_json" | jq -c '.[]' 2>/dev/null || true)

	# Sync platform issue assignees → TODO.md assignee: field (t165 bi-directional sync)
	local assignee_synced=0
	while IFS= read -r issue_line; do
		local issue_number
		issue_number=$(echo "$issue_line" | jq -r '.number' 2>/dev/null || echo "")
		local issue_title
		issue_title=$(echo "$issue_line" | jq -r '.title' 2>/dev/null || echo "")
		local assignee_login
		assignee_login=$(echo "$issue_line" | jq -r '.assignees[0].login // empty' 2>/dev/null || echo "")

		local task_id
		task_id=$(echo "$issue_title" | grep -oE '^t[0-9]+(\.[0-9]+)*' || echo "")
		if [[ -z "$task_id" || -z "$assignee_login" ]]; then
			continue
		fi

		# Check if task exists in TODO.md (any indent level)
		if ! grep -qE "^\s*- \[.\] ${task_id} " "$todo_file" 2>/dev/null; then
			continue
		fi

		# Check if TODO.md already has an assignee: on this task
		local task_line_content
		task_line_content=$(grep -E "^\s*- \[.\] ${task_id} " "$todo_file" | head -1 || echo "")
		local existing_assignee
		existing_assignee=$(echo "$task_line_content" | grep -oE 'assignee:[A-Za-z0-9._@-]+' | head -1 | sed 's/^assignee://' || echo "")

		if [[ -n "$existing_assignee" ]]; then
			# Already has an assignee — TODO.md is authoritative, don't overwrite
			continue
		fi

		# No assignee in TODO.md but issue has assignee — sync it
		if [[ "$DRY_RUN" == "true" ]]; then
			print_info "[DRY-RUN] Would add assignee:$assignee_login to $task_id (from $_DETECTED_PLATFORM #$issue_number)"
			assignee_synced=$((assignee_synced + 1))
			continue
		fi

		# Add assignee:login before logged: or at end of line
		local line_num
		line_num=$(grep -nE "^\s*- \[.\] ${task_id} " "$todo_file" | head -1 | cut -d: -f1)
		if [[ -n "$line_num" ]]; then
			local current_line
			current_line=$(sed -n "${line_num}p" "$todo_file")
			local new_line
			if echo "$current_line" | grep -qE 'logged:'; then
				new_line=$(echo "$current_line" | sed -E "s/( logged:)/ assignee:${assignee_login}\1/")
			else
				new_line="${current_line} assignee:${assignee_login}"
			fi
			sed_inplace "${line_num}s|.*|${new_line}|" "$todo_file"
			log_verbose "Synced assignee:$assignee_login to $task_id (from $_DETECTED_PLATFORM #$issue_number)"
			assignee_synced=$((assignee_synced + 1))
		fi
	done < <(echo "$issues_json" | jq -c '.[]' 2>/dev/null || true)

	# Summary
	echo ""
	echo "=== Pull Summary ==="
	echo "Refs synced to TODO.md:    $synced"
	echo "Assignees synced:          $assignee_synced"
	echo "Orphan issues (open):      $orphan_open"
	echo "Orphan issues (closed):    $orphan_closed"
	echo ""

	if [[ $orphan_open -gt 0 ]]; then
		print_warning "$orphan_open open issue(s) have no TODO.md entry: $orphan_open_list"
		print_info "Add tasks to TODO.md or close orphan issues on $_DETECTED_PLATFORM"
	fi
	if [[ $synced -eq 0 && $assignee_synced -eq 0 && $orphan_open -eq 0 ]]; then
		print_success "TODO.md refs are up to date with $_DETECTED_PLATFORM"
	fi

	return 0
}

# fix_gh_ref_in_todo, add_gh_ref_to_todo, add_pr_ref_to_todo,
# task_has_completion_evidence, _build_pr_url, find_closing_pr
# — sourced from issue-sync-lib.sh

# Close: close GitHub issue when TODO.md task is completed
# Guard (t163): requires merged PR or verified: field before closing
# Fallback (t179.1): search by task ID in issue title when ref:GH# doesn't match
cmd_close() {
	local target_task="${1:-}"
	local project_root
	project_root=$(find_project_root) || return 1
	local repo_slug="${REPO_SLUG:-$(detect_repo_slug "$project_root")}"
	local todo_file="$project_root/TODO.md"

	init_platform "$project_root"
	verify_platform_auth "$_DETECTED_PLATFORM" || return 1

	# t283: Performance optimization — pre-fetch all open issues in ONE API call,
	# then only process completed tasks that have a matching open issue.
	# Before: iterated all 533+ completed tasks × 2-5 API calls each = 2000+ calls, 5+ min.
	# After: 1 bulk fetch + only process tasks with open issues = ~30 API calls, <30s.

	local closed=0
	local skipped=0
	local ref_fixed=0

	if [[ -n "$target_task" ]]; then
		# Single-task mode: process just this one task (original per-task logic)
		_close_single_task "$target_task" "$todo_file" "$repo_slug"
		return $?
	fi

	# Bulk mode: fetch all open issues once, build task_id -> issue_number map
	log_verbose "Fetching all open issues from $repo_slug..."
	local open_issues_json
	open_issues_json=$(platform_list_issues "$repo_slug" "open" 500)

	# Build newline-delimited lookup: "task_id|issue_number" per line
	# Avoids bash associative arrays which break under set -u on empty arrays
	local open_issue_lines=""
	while IFS='|' read -r num title; do
		[[ -z "$num" ]] && continue
		local tid
		tid=$(echo "$title" | grep -oE '^t[0-9]+(\.[0-9]+)*' || echo "")
		if [[ -n "$tid" ]]; then
			open_issue_lines="${open_issue_lines}${tid}|${num}"$'\n'
		fi
	done < <(echo "$open_issues_json" | jq -r '.[] | "\(.number)|\(.title)"' 2>/dev/null || true)

	local open_count
	if [[ -z "$open_issue_lines" ]]; then
		open_count=0
	else
		open_count=$(echo -n "$open_issue_lines" | grep -c '.' || echo "0")
	fi
	log_verbose "Found $open_count open issues with task IDs"

	if [[ "$open_count" -eq 0 ]]; then
		print_info "No open issues to close"
		return 0
	fi

	# Now iterate only completed tasks that have a matching open issue
	# This is the key optimization: instead of checking 533 tasks against the API,
	# we only process the ~20-30 that actually have open issues
	while IFS= read -r line; do
		local task_id
		task_id=$(echo "$line" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1 || echo "")
		[[ -z "$task_id" ]] && continue

		# Cross-repo guard (t1235)
		local task_repo_slug=""
		task_repo_slug=$(_lookup_task_repo_slug "$task_id")
		if [[ -n "$task_repo_slug" && "$task_repo_slug" != "$repo_slug" ]]; then
			log_verbose "$task_id belongs to $task_repo_slug, not $repo_slug — skipping close"
			continue
		fi

		# Lookup task_id in the open issues list (grep for exact match at line start)
		local mapped_line
		mapped_line=$(echo "$open_issue_lines" | grep -E "^${task_id}\|" | head -1 || echo "")
		if [[ -z "$mapped_line" ]]; then
			# No open issue for this completed task — skip (nothing to close)
			continue
		fi
		local mapped_issue="${mapped_line#*|}"

		# Check 1: Does this task have a ref:GH# that matches an open issue?
		local issue_number=""
		local ref_number
		ref_number=$(echo "$line" | grep -oE 'ref:GH#[0-9]+' | head -1 | sed 's/ref:GH#//' || echo "")

		if [[ -n "$ref_number" ]]; then
			# Task has ref:GH# AND an open issue exists for this task ID
			issue_number="$mapped_issue"
			# Verify ref matches (fix stale refs)
			if [[ "$ref_number" != "$issue_number" ]]; then
				log_verbose "$task_id: ref:GH#$ref_number doesn't match open issue #$issue_number, fixing..."
				if [[ "$DRY_RUN" != "true" ]]; then
					fix_gh_ref_in_todo "$task_id" "$ref_number" "$issue_number" "$todo_file"
					ref_fixed=$((ref_fixed + 1))
				fi
			fi
		else
			# No ref:GH# but an open issue exists — use it and fix the ref
			issue_number="$mapped_issue"
			log_verbose "$task_id: no ref:GH# but found open issue #$issue_number"
			if [[ "$DRY_RUN" != "true" ]]; then
				add_gh_ref_to_todo "$task_id" "$issue_number" "$todo_file"
				ref_fixed=$((ref_fixed + 1))
			fi
		fi

		if [[ -z "$issue_number" || "$issue_number" == "null" ]]; then
			continue
		fi

		# Extract task block for evidence checking and PR discovery
		local task_with_notes
		task_with_notes=$(extract_task_block "$task_id" "$todo_file")
		local task_line
		task_line=$(grep -E "^\s*- \[.\] ${task_id} " "$todo_file" | head -1 || echo "")
		if [[ -z "$task_with_notes" ]]; then
			task_with_notes="$task_line"
		fi

		# t1004: Find the closing PR BEFORE evidence check (chicken-and-egg fix)
		# This allows us to discover and write pr:#NNN to TODO.md, which then
		# satisfies the evidence check on the next pass
		local closing_pr_info closing_pr_number closing_pr_url
		closing_pr_info=$(find_closing_pr "$task_with_notes" "$task_id" "$repo_slug" 2>/dev/null || echo "")
		closing_pr_number=""
		closing_pr_url=""
		if [[ -n "$closing_pr_info" ]]; then
			closing_pr_number="${closing_pr_info%%|*}"
			closing_pr_url="${closing_pr_info#*|}"

			# t280: Write pr:#NNN back to TODO.md if missing (proof-log backfill)
			if [[ "$DRY_RUN" != "true" && -n "$closing_pr_number" ]]; then
				add_pr_ref_to_todo "$task_id" "$closing_pr_number" "$todo_file"
				# Re-read task line after adding pr:#NNN
				task_line=$(grep -E "^\s*- \[.\] ${task_id} " "$todo_file" | head -1 || echo "")
				task_with_notes=$(extract_task_block "$task_id" "$todo_file")
				if [[ -z "$task_with_notes" ]]; then
					task_with_notes="$task_line"
				fi
			fi
		fi

		# Guard: verify task has completion evidence (merged PR or verified: field)
		if [[ "$FORCE_CLOSE" != "true" ]] && ! task_has_completion_evidence "$task_with_notes" "$task_id" "$repo_slug"; then
			print_warning "Skipping #$issue_number ($task_id): no merged PR or verified: field found"
			log_verbose "  To force close: FORCE_CLOSE=true issue-sync-helper.sh close $task_id"
			log_verbose "  To verify: add 'verified:$(date +%Y-%m-%d)' to the task line in TODO.md"
			skipped=$((skipped + 1))
			continue
		fi

		# Build close comment with PR reference for auditability (t220)
		local close_comment="Completed. Task $task_id marked done in TODO.md."
		if [[ -n "$closing_pr_number" ]]; then
			close_comment="Completed via PR #${closing_pr_number}. Task $task_id marked done in TODO.md."
			if [[ -n "$closing_pr_url" ]]; then
				close_comment="Completed via [PR #${closing_pr_number}](${closing_pr_url}). Task $task_id marked done in TODO.md."
			fi
		elif echo "$task_with_notes" | grep -qE 'verified:[0-9]{4}-[0-9]{2}-[0-9]{2}'; then
			local verified_date
			verified_date=$(echo "$task_with_notes" | grep -oE 'verified:[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1 | sed 's/verified://')
			close_comment="Completed (verified: $verified_date). Task $task_id marked done in TODO.md."
		fi

		if [[ "$DRY_RUN" == "true" ]]; then
			print_info "[DRY-RUN] Would close #$issue_number ($task_id)"
			if [[ -n "$closing_pr_number" ]]; then
				print_info "  Closing PR: #$closing_pr_number"
			fi
			closed=$((closed + 1))
			continue
		fi

		if platform_close_issue "$repo_slug" "$issue_number" "$close_comment"; then
			# Update status label to status:done, remove all other status labels (t212, t1009)
			platform_create_label "$repo_slug" "status:done" "6F42C1" "Task is complete"
			platform_add_labels "$repo_slug" "$issue_number" "status:done"
			platform_remove_labels "$repo_slug" "$issue_number" "status:available,status:queued,status:claimed,status:in-review,status:blocked,status:verify-failed"
			print_success "Closed #$issue_number ($task_id)"
			closed=$((closed + 1))
		else
			print_error "Failed to close #$issue_number ($task_id)"
		fi
	done < <(strip_code_fences <"$todo_file" | grep -E '^\s*- \[x\] t[0-9]+' || true)

	print_info "Close complete: $closed closed, $skipped skipped (no evidence), $ref_fixed refs fixed"
	return 0
}

# Single-task close helper (used by cmd_close for targeted single-task mode)
_close_single_task() {
	local task_id="$1"
	local todo_file="$2"
	local repo_slug="$3"

	# Cross-repo guard (t1235)
	local task_repo_slug=""
	task_repo_slug=$(_lookup_task_repo_slug "$task_id")
	if [[ -n "$task_repo_slug" && "$task_repo_slug" != "$repo_slug" ]]; then
		print_warning "$task_id belongs to $task_repo_slug, not $repo_slug — skipping close"
		return 0
	fi

	local task_line
	task_line=$(grep -E "^\s*- \[.\] ${task_id} " "$todo_file" | head -1 || echo "")
	local issue_number
	issue_number=$(echo "$task_line" | grep -oE 'ref:GH#[0-9]+' | head -1 | sed 's/ref:GH#//' || echo "")

	# Fallback: search by task ID in issue title when ref:GH# is missing (multi-platform)
	if [[ -z "$issue_number" ]]; then
		log_verbose "$task_id: no ref:GH# in TODO.md, searching $_DETECTED_PLATFORM by title..."
		issue_number=$(platform_find_issue_by_title "$repo_slug" "${task_id}:" "open" 50)
		if [[ -n "$issue_number" && "$issue_number" != "null" ]]; then
			log_verbose "$task_id: found open issue #$issue_number by title search on $_DETECTED_PLATFORM"
			if [[ "$DRY_RUN" != "true" ]]; then
				add_gh_ref_to_todo "$task_id" "$issue_number" "$todo_file"
			fi
		else
			print_info "$task_id: no matching open issue found on $_DETECTED_PLATFORM"
			return 0
		fi
	fi

	if [[ -z "$issue_number" || "$issue_number" == "null" ]]; then
		return 0
	fi

	# Check if already closed (multi-platform)
	local issue_state
	local issue_json
	issue_json=$(platform_view_issue "$repo_slug" "$issue_number")
	issue_state=$(echo "$issue_json" | jq -r '.state // empty' 2>/dev/null || echo "")
	if [[ "$issue_state" == "CLOSED" || "$issue_state" == "closed" ]]; then
		log_verbose "#$issue_number already closed"
		return 0
	fi

	# Verify completion evidence
	local task_with_notes
	task_with_notes=$(extract_task_block "$task_id" "$todo_file")
	if [[ -z "$task_with_notes" ]]; then
		task_with_notes="$task_line"
	fi

	if [[ "$FORCE_CLOSE" != "true" ]] && ! task_has_completion_evidence "$task_with_notes" "$task_id" "$repo_slug"; then
		print_warning "Skipping #$issue_number ($task_id): no merged PR or verified: field found"
		return 0
	fi

	# Find closing PR
	local closing_pr_info closing_pr_number closing_pr_url
	closing_pr_info=$(find_closing_pr "$task_with_notes" "$task_id" "$repo_slug" 2>/dev/null || echo "")
	closing_pr_number=""
	closing_pr_url=""
	if [[ -n "$closing_pr_info" ]]; then
		closing_pr_number="${closing_pr_info%%|*}"
		closing_pr_url="${closing_pr_info#*|}"

		# t280: Write pr:#NNN back to TODO.md if missing (proof-log backfill)
		if [[ "$DRY_RUN" != "true" && -n "$closing_pr_number" ]]; then
			add_pr_ref_to_todo "$task_id" "$closing_pr_number" "$todo_file"
		fi
	fi

	local close_comment="Completed. Task $task_id marked done in TODO.md."
	if [[ -n "$closing_pr_number" && -n "$closing_pr_url" ]]; then
		close_comment="Completed via [PR #${closing_pr_number}](${closing_pr_url}). Task $task_id marked done in TODO.md."
	elif [[ -n "$closing_pr_number" ]]; then
		close_comment="Completed via PR #${closing_pr_number}. Task $task_id marked done in TODO.md."
	fi

	if [[ "$DRY_RUN" == "true" ]]; then
		print_info "[DRY-RUN] Would close #$issue_number ($task_id)"
		return 0
	fi

	if platform_close_issue "$repo_slug" "$issue_number" "$close_comment"; then
		# Update status label to status:done, remove all other status labels (t212, t1009)
		platform_create_label "$repo_slug" "status:done" "6F42C1" "Task is complete"
		platform_add_labels "$repo_slug" "$issue_number" "status:done"
		platform_remove_labels "$repo_slug" "$issue_number" "status:available,status:queued,status:claimed,status:in-review,status:blocked,status:verify-failed"
		print_success "Closed #$issue_number ($task_id)"
	else
		print_error "Failed to close #$issue_number ($task_id)"
	fi
	return 0
}

# Status: show sync drift between TODO.md and platform (multi-platform)
cmd_status() {
	local project_root
	project_root=$(find_project_root) || return 1
	local repo_slug="${REPO_SLUG:-$(detect_repo_slug "$project_root")}"
	local todo_file="$project_root/TODO.md"

	init_platform "$project_root"
	verify_platform_auth "$_DETECTED_PLATFORM" || return 1

	print_info "Checking sync status for $repo_slug ($_DETECTED_PLATFORM)..."

	# Count tasks in TODO.md (include both top-level and indented subtasks)
	# strip_code_fences prevents format-example lines from inflating counts
	local total_open
	total_open=$(strip_code_fences <"$todo_file" | grep -cE '^\s*- \[ \] t[0-9]+' || echo "0")
	local total_completed
	total_completed=$(strip_code_fences <"$todo_file" | grep -cE '^\s*- \[x\] t[0-9]+' || echo "0")
	local with_ref
	with_ref=$(strip_code_fences <"$todo_file" | grep -cE '^\s*- \[ \] t[0-9]+.*ref:GH#' || echo "0")
	local without_ref
	without_ref=$((total_open - with_ref))

	# Count platform issues (multi-platform)
	local platform_open_json platform_closed_json
	platform_open_json=$(platform_list_issues "$repo_slug" "open" 500)
	platform_closed_json=$(platform_list_issues "$repo_slug" "closed" 500)
	local gh_open gh_closed
	gh_open=$(echo "$platform_open_json" | jq 'length' 2>/dev/null || echo "0")
	gh_closed=$(echo "$platform_closed_json" | jq 'length' 2>/dev/null || echo "0")

	# Count completed tasks with open issues (drift)
	local completed_with_open_issues=0
	while IFS= read -r line; do
		local issue_num
		issue_num=$(echo "$line" | grep -oE 'ref:GH#[0-9]+' | head -1 | sed 's/ref:GH#//' || echo "")
		if [[ -n "$issue_num" ]]; then
			local issue_json state
			issue_json=$(platform_view_issue "$repo_slug" "$issue_num")
			state=$(echo "$issue_json" | jq -r '.state // empty' 2>/dev/null || echo "")
			if [[ "$state" == "OPEN" || "$state" == "open" || "$state" == "opened" ]]; then
				completed_with_open_issues=$((completed_with_open_issues + 1))
				print_warning "DRIFT: $line"
			fi
		fi
	done < <(strip_code_fences <"$todo_file" | grep -E '^\s*- \[x\] t[0-9]+.*ref:GH#' || true)

	echo ""
	echo "=== Sync Status ($repo_slug on $_DETECTED_PLATFORM) ==="
	echo "TODO.md open tasks:        $total_open"
	echo "  - with issue ref:        $with_ref"
	echo "  - without issue ref:     $without_ref"
	echo "TODO.md completed tasks:   $total_completed"
	echo "Platform open issues:      $gh_open"
	echo "Platform closed issues:    $gh_closed"
	echo "Drift (done but open):     $completed_with_open_issues"
	echo ""

	if [[ $without_ref -gt 0 ]]; then
		print_warning "$without_ref open tasks have no $_DETECTED_PLATFORM issue. Run: issue-sync-helper.sh push"
	fi
	if [[ $completed_with_open_issues -gt 0 ]]; then
		print_warning "$completed_with_open_issues completed tasks have open $_DETECTED_PLATFORM issues. Run: issue-sync-helper.sh close"
	fi
	if [[ $without_ref -eq 0 && $completed_with_open_issues -eq 0 ]]; then
		print_success "TODO.md and $_DETECTED_PLATFORM issues are in sync"
	fi

	return 0
}

# Reconcile: fix mismatched ref:GH# values in TODO.md (t179.2)
# Scans all tasks with ref:GH#, verifies the issue number matches an issue
# with the task ID in its title, and fixes mismatches.
# Also finds open issues for completed tasks and closes them.
cmd_reconcile() {
	local project_root
	project_root=$(find_project_root) || return 1
	local repo_slug="${REPO_SLUG:-$(detect_repo_slug "$project_root")}"
	local todo_file="$project_root/TODO.md"

	init_platform "$project_root"
	verify_platform_auth "$_DETECTED_PLATFORM" || return 1

	print_info "Reconciling ref:GH# values in $repo_slug ($_DETECTED_PLATFORM)..."

	local ref_fixed=0
	local ref_ok=0
	local stale_closed=0
	local orphan_issues=0

	# Phase 1: Verify all ref:GH# values in TODO.md match actual issues
	while IFS= read -r line; do
		local tid
		tid=$(echo "$line" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1 || echo "")
		local gh_ref
		gh_ref=$(echo "$line" | grep -oE 'ref:GH#[0-9]+' | head -1 | sed 's/ref:GH#//' || echo "")

		if [[ -z "$tid" || -z "$gh_ref" ]]; then
			continue
		fi

		# Cross-repo guard (t1235)
		local task_repo_slug=""
		task_repo_slug=$(_lookup_task_repo_slug "$tid")
		if [[ -n "$task_repo_slug" && "$task_repo_slug" != "$repo_slug" ]]; then
			log_verbose "$tid belongs to $task_repo_slug, not $repo_slug — skipping reconcile"
			continue
		fi

		# Verify the issue title matches this task ID (multi-platform)
		local issue_json_view
		issue_json_view=$(platform_view_issue "$repo_slug" "$gh_ref")
		local issue_title
		issue_title=$(echo "$issue_json_view" | jq -r '.title // empty' 2>/dev/null || echo "")
		local issue_task_id
		issue_task_id=$(echo "$issue_title" | grep -oE '^t[0-9]+(\.[0-9]+)*' || echo "")

		if [[ "$issue_task_id" == "$tid" ]]; then
			ref_ok=$((ref_ok + 1))
			continue
		fi

		# Mismatch — search for the correct issue (multi-platform)
		print_warning "MISMATCH: $tid has ref:GH#$gh_ref but issue title is '$issue_title'"
		local correct_number
		correct_number=$(platform_find_issue_by_title "$repo_slug" "${tid}:" "all" 50)

		if [[ -n "$correct_number" && "$correct_number" != "null" && "$correct_number" != "$gh_ref" ]]; then
			if [[ "$DRY_RUN" == "true" ]]; then
				print_info "[DRY-RUN] Would fix $tid: ref:GH#$gh_ref -> ref:GH#$correct_number"
			else
				fix_gh_ref_in_todo "$tid" "$gh_ref" "$correct_number" "$todo_file"
				print_success "Fixed $tid: ref:GH#$gh_ref -> ref:GH#$correct_number"
			fi
			ref_fixed=$((ref_fixed + 1))
		elif [[ -z "$correct_number" || "$correct_number" == "null" ]]; then
			print_warning "$tid: no matching issue found on $_DETECTED_PLATFORM (ref:GH#$gh_ref may be stale)"
		fi
	done < <(strip_code_fences <"$todo_file" | grep -E '^\s*- \[.\] t[0-9]+.*ref:GH#[0-9]+' || true)

	# Phase 2: Find open issues for completed tasks (including those without ref:GH#)
	local open_issues_json
	open_issues_json=$(platform_list_issues "$repo_slug" "open" 200)

	while IFS= read -r issue_line; do
		local issue_number
		issue_number=$(echo "$issue_line" | jq -r '.number' 2>/dev/null || echo "")
		local issue_title
		issue_title=$(echo "$issue_line" | jq -r '.title' 2>/dev/null || echo "")

		local issue_tid
		issue_tid=$(echo "$issue_title" | grep -oE '^t[0-9]+(\.[0-9]+)*' || echo "")
		if [[ -z "$issue_tid" ]]; then
			continue
		fi

		# Check if task is completed in TODO.md (any indent level)
		if grep -qE "^\s*- \[x\] ${issue_tid} " "$todo_file" 2>/dev/null; then
			print_warning "STALE: GH#$issue_number ($issue_tid) is open but task is completed"
			stale_closed=$((stale_closed + 1))
		fi

		# Check if task exists at all in TODO.md (any indent level)
		if ! grep -qE "^\s*- \[.\] ${issue_tid} " "$todo_file" 2>/dev/null; then
			log_verbose "ORPHAN: #$issue_number ($issue_tid) has no matching TODO.md entry"
			orphan_issues=$((orphan_issues + 1))
		fi
	done < <(echo "$open_issues_json" | jq -c '.[]' 2>/dev/null || true)

	echo ""
	echo "=== Reconciliation Report ==="
	echo "Refs verified OK:          $ref_ok"
	echo "Refs fixed (mismatch):     $ref_fixed"
	echo "Stale open issues:         $stale_closed"
	echo "Orphan issues (no task):   $orphan_issues"
	echo ""

	if [[ $stale_closed -gt 0 ]]; then
		print_info "Run 'issue-sync-helper.sh close' to close stale issues"
	fi
	if [[ $ref_fixed -gt 0 && "$DRY_RUN" != "true" ]]; then
		print_success "Fixed $ref_fixed mismatched refs in TODO.md"
	fi
	if [[ $ref_fixed -eq 0 && $stale_closed -eq 0 && $orphan_issues -eq 0 ]]; then
		print_success "All refs are correct, no drift detected"
	fi

	return 0
}

# Parse: display parsed task context (dry-run / debug)
cmd_parse() {
	local task_id="${1:-}"
	if [[ -z "$task_id" ]]; then
		print_error "Usage: issue-sync-helper.sh parse tNNN"
		return 1
	fi

	local project_root
	project_root=$(find_project_root) || return 1
	local todo_file="$project_root/TODO.md"

	echo "=== Task Block ==="
	local block
	block=$(extract_task_block "$task_id" "$todo_file")
	echo "$block"
	echo ""

	echo "=== Parsed Fields ==="
	local first_line
	first_line=$(echo "$block" | head -1)
	parse_task_line "$first_line"
	echo ""

	echo "=== Subtasks ==="
	extract_subtasks "$block"
	echo ""

	echo "=== Notes ==="
	extract_notes "$block"
	echo ""

	# Check for plan link
	local parsed
	parsed=$(parse_task_line "$first_line")
	local plan_link
	plan_link=$(echo "$parsed" | grep '^plan_link=' | cut -d= -f2-)
	if [[ -n "$plan_link" ]]; then
		echo "=== Plan Section ==="
		local plan_section
		plan_section=$(extract_plan_section "$plan_link" "$project_root")
		if [[ -n "$plan_section" ]]; then
			echo "Purpose:"
			extract_plan_purpose "$plan_section"
			echo ""
			echo "Decisions:"
			extract_plan_decisions "$plan_section"
			echo ""
			echo "Progress:"
			extract_plan_progress "$plan_section"
		else
			echo "(no plan section found for anchor: $plan_link)"
		fi
		echo ""
	fi

	echo "=== Related Files ==="
	find_related_files "$task_id" "$project_root"
	echo ""

	echo "=== Composed Issue Body ==="
	compose_issue_body "$task_id" "$project_root"

	return 0
}

# =============================================================================
# Main
# =============================================================================

cmd_help() {
	cat <<'EOF'
aidevops Issue Sync Helper

Bi-directional sync between TODO.md/PLANS.md and platform issues.
Supports GitHub (gh CLI), Gitea (REST API), and GitLab (REST API).
Platform is auto-detected from git remote URL, or set with --platform.

Usage: issue-sync-helper.sh [command] [options]

Commands:
  push [tNNN]     Create issues from TODO.md tasks (all open or specific)
  enrich [tNNN]   Update existing issue bodies with full context from PLANS.md
  pull            Sync issue refs back to TODO.md + detect orphan issues
  close [tNNN]    Close issues for completed TODO.md tasks
  reconcile       Fix mismatched ref:GH# values and detect drift (t179.2)
  status          Show sync drift between TODO.md and platform
  parse [tNNN]    Parse and display task context (debug/dry-run)
  help            Show this help message

Options:
  --repo SLUG     Override repo slug (default: auto-detect from git remote)
  --platform P    Override platform: github, gitea, gitlab (default: auto-detect)
  --dry-run       Show what would be done without making changes
  --verbose       Show detailed output
  --force         Force close: skip merged-PR/verified check (use with caution)

Platform Authentication:
  GitHub:  gh CLI (gh auth login) or GH_TOKEN/GITHUB_TOKEN env var
  Gitea:   GITEA_TOKEN env var (personal access token)
  GitLab:  GITLAB_TOKEN env var (personal access token)

Examples:
  issue-sync-helper.sh push                    # Push all unsynced tasks
  issue-sync-helper.sh push t020               # Push specific task
  issue-sync-helper.sh push --platform gitea   # Push to Gitea instance
  issue-sync-helper.sh enrich t020             # Enrich issue with plan context
  issue-sync-helper.sh pull                    # Sync refs to TODO.md
  issue-sync-helper.sh close                   # Close issues for done tasks
  issue-sync-helper.sh reconcile --dry-run     # Preview reconciliation
  issue-sync-helper.sh status                  # Show sync drift
  issue-sync-helper.sh parse t020              # Debug: show parsed context
EOF
	return 0
}

main() {
	local command=""
	local positional_args=()

	# Parse arguments
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--repo)
			REPO_SLUG="$2"
			shift 2
			;;
		--platform)
			PLATFORM="$2"
			shift 2
			;;
		--dry-run)
			DRY_RUN="true"
			shift
			;;
		--verbose)
			VERBOSE="true"
			shift
			;;
		--force)
			FORCE_CLOSE="true"
			shift
			;;
		help | --help | -h)
			cmd_help
			return 0
			;;
		*)
			positional_args+=("$1")
			shift
			;;
		esac
	done

	command="${positional_args[0]:-help}"

	case "$command" in
	push)
		cmd_push "${positional_args[1]:-}"
		;;
	enrich)
		cmd_enrich "${positional_args[1]:-}"
		;;
	pull)
		cmd_pull
		;;
	close)
		cmd_close "${positional_args[1]:-}"
		;;
	reconcile)
		cmd_reconcile
		;;
	status)
		cmd_status
		;;
	parse)
		cmd_parse "${positional_args[1]:-}"
		;;
	help)
		cmd_help
		;;
	*)
		print_error "Unknown command: $command"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
