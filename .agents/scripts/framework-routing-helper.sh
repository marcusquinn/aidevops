#!/usr/bin/env bash
# framework-routing-helper.sh - Detect and route framework-level tasks to the aidevops repo
#
# Solves: GH#5149 — workers create framework tasks in project repos instead of
# routing to aidevops. Prose-only guidance (GH#2849) is insufficient for
# autonomous workers under supervisor dispatch.
#
# This helper provides structural enforcement:
#   1. is-framework: Detect whether a task description references framework-level
#      concerns (returns 0 = framework, 1 = project, 2 = uncertain)
#   2. get-aidevops-path: Resolve the local path to the aidevops repo
#   3. get-aidevops-slug: Resolve the GitHub slug for the aidevops repo
#   4. log-framework-issue: Create an issue on the aidevops repo for a
#      framework-level observation (wraps gh issue create with dedup)
#
# Usage:
#   framework-routing-helper.sh is-framework "task title or description"
#   framework-routing-helper.sh get-aidevops-path
#   framework-routing-helper.sh get-aidevops-slug
#   framework-routing-helper.sh log-framework-issue --title "..." [--body "..."] [--labels "..."]
#
# Exit codes:
#   is-framework: 0 = framework, 1 = project, 2 = uncertain/error
#   log-framework-issue: 0 = issue created, 1 = error, 2 = duplicate found
#   get-aidevops-*: 0 = found, 1 = not found

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit

# Source shared logging if available
if [[ -f "${SCRIPT_DIR}/shared-constants.sh" ]]; then
	# shellcheck source=/dev/null
	source "${SCRIPT_DIR}/shared-constants.sh"
fi

# Ensure log functions exist (fallback if shared-constants not loaded)
if ! type log_info &>/dev/null; then
	log_info() { echo "[INFO] $*" >&2; }
	log_warn() { echo "[WARN] $*" >&2; }
	log_error() { echo "[ERROR] $*" >&2; }
	log_success() { echo "[OK] $*" >&2; }
fi

# =============================================================================
# Framework indicator patterns
# =============================================================================
# These patterns identify task descriptions that reference framework-level
# concerns. The detection is intentionally broad — false positives (flagging a
# project task as framework) are cheap (a warning), while false negatives
# (missing a framework task) cause the exact bug we're fixing.
#
# Pattern categories:
#   1. Framework file paths (~/.aidevops/, .agents/, prompts/build.txt)
#   2. Framework script names (ai-lifecycle, pulse-wrapper, dispatch, supervisor)
#   3. Framework concepts (cross-repo, task routing, model tier, pulse logic)
#   4. Framework components (claim-task-id, issue-sync, headless-runtime)

# Path patterns that indicate framework-level work
# shellcheck disable=SC2088 # Tilde is intentional — matching literal "~/.aidevops" in text
readonly FRAMEWORK_PATH_PATTERNS=(
	'~/.aidevops'
	'.aidevops/'
	'.agents/'
	'prompts/build.txt'
	'agents/scripts/'
	'agents/AGENTS.md'
	'setup.sh'
)

# Script/component names that are framework-level
readonly FRAMEWORK_COMPONENT_PATTERNS=(
	'ai-lifecycle'
	'pulse-wrapper'
	'pulse-session'
	'supervisor'
	'dispatch\.sh'
	'pre-edit-check'
	'claim-task-id'
	'issue-sync'
	'headless-runtime'
	'worker-lifecycle'
	'worker-watchdog'
	'circuit-breaker'
	'model-availability'
	'framework-routing'
	'session-miner'
	'memory-helper'
	'shared-constants'
	'config-helper'
	'version-manager'
	'linters-local'
)

# Conceptual patterns that indicate framework-level concerns
readonly FRAMEWORK_CONCEPT_PATTERNS=(
	'cross-repo orchestration'
	'task routing'
	'self-improvement routing'
	'model tier'
	'pulse logic'
	'supervisor pipeline'
	'agent prompt'
	'framework bug'
	'framework task'
	'framework-level'
	'aidevops framework'
	'worker dispatch'
	'dispatch protocol'
	'worktree management'
)

# =============================================================================
# is_framework_task — detect whether a description is framework-level
# =============================================================================
# Arguments:
#   $1 - task title or description text (must be non-empty; caller validates)
# Returns:
#   0 = framework-level (high confidence)
#   1 = project-level (no framework indicators found)
#   2 = uncertain
# Outputs:
#   Machine-readable result on stdout: "framework", "project", or "uncertain"
#   Match details on stderr
is_framework_task() {
	local description="$1"
	local match_count=0
	local matched_patterns=""

	# Normalise to lowercase for matching
	local desc_lower
	desc_lower=$(printf '%s' "$description" | tr '[:upper:]' '[:lower:]')

	# Check path patterns
	local pattern
	for pattern in "${FRAMEWORK_PATH_PATTERNS[@]}"; do
		local pattern_lower
		pattern_lower=$(printf '%s' "$pattern" | tr '[:upper:]' '[:lower:]')
		if [[ "$desc_lower" == *"$pattern_lower"* ]]; then
			match_count=$((match_count + 1))
			matched_patterns="${matched_patterns}path:${pattern} "
		fi
	done

	# Check component patterns (regex-based for word boundaries)
	for pattern in "${FRAMEWORK_COMPONENT_PATTERNS[@]}"; do
		local pattern_lower
		pattern_lower=$(printf '%s' "$pattern" | tr '[:upper:]' '[:lower:]')
		if [[ "$desc_lower" =~ $pattern_lower ]]; then
			match_count=$((match_count + 1))
			matched_patterns="${matched_patterns}component:${pattern} "
		fi
	done

	# Check concept patterns
	for pattern in "${FRAMEWORK_CONCEPT_PATTERNS[@]}"; do
		local pattern_lower
		pattern_lower=$(printf '%s' "$pattern" | tr '[:upper:]' '[:lower:]')
		if [[ "$desc_lower" == *"$pattern_lower"* ]]; then
			match_count=$((match_count + 1))
			matched_patterns="${matched_patterns}concept:${pattern} "
		fi
	done

	if [[ $match_count -ge 2 ]]; then
		log_info "Framework task detected (${match_count} matches: ${matched_patterns})"
		echo "framework"
		return 0
	elif [[ $match_count -eq 1 ]]; then
		log_warn "Possible framework task (1 match: ${matched_patterns}) — review routing"
		echo "uncertain"
		return 2
	else
		echo "project"
		return 1
	fi
}

# =============================================================================
# get_aidevops_path — resolve the local filesystem path to the aidevops repo
# =============================================================================
# Checks repos.json first, then falls back to common locations.
# Returns:
#   0 = found (path on stdout)
#   1 = not found
get_aidevops_path() {
	local repos_json="${HOME}/.config/aidevops/repos.json"

	# Primary: check repos.json
	if [[ -f "$repos_json" ]] && command -v jq &>/dev/null; then
		local path
		path=$(jq -r '.initialized_repos[] | select(.slug | test("aidevops$")) | .path' "$repos_json" 2>/dev/null | head -1)
		if [[ -n "$path" && -d "$path" ]]; then
			echo "$path"
			return 0
		fi
	fi

	# Fallback: check common locations
	local candidate
	for candidate in \
		"${HOME}/Git/aidevops" \
		"${HOME}/git/aidevops" \
		"${HOME}/Projects/aidevops" \
		"${HOME}/Code/aidevops"; do
		if [[ -d "$candidate/.git" ]]; then
			echo "$candidate"
			return 0
		fi
	done

	log_warn "Could not find aidevops repo path"
	return 1
}

# =============================================================================
# get_aidevops_slug — resolve the GitHub slug for the aidevops repo
# =============================================================================
# Returns:
#   0 = found (slug on stdout)
#   1 = not found
get_aidevops_slug() {
	local repos_json="${HOME}/.config/aidevops/repos.json"

	# Primary: check repos.json
	if [[ -f "$repos_json" ]] && command -v jq &>/dev/null; then
		local slug
		slug=$(jq -r '.initialized_repos[] | select(.slug | test("aidevops$")) | .slug' "$repos_json" 2>/dev/null | head -1)
		if [[ -n "$slug" ]]; then
			echo "$slug"
			return 0
		fi
	fi

	# Fallback: resolve from git remote
	local aidevops_path
	if aidevops_path=$(get_aidevops_path); then
		local remote_url
		remote_url=$(git -C "$aidevops_path" remote get-url origin 2>/dev/null || echo "")
		if [[ -n "$remote_url" ]]; then
			local slug
			slug=$(printf '%s' "$remote_url" | sed 's|.*github\.com[:/]||;s|\.git$||')
			if [[ -n "$slug" ]]; then
				echo "$slug"
				return 0
			fi
		fi
	fi

	log_warn "Could not resolve aidevops slug"
	return 1
}

# =============================================================================
# log_framework_issue — create a GitHub issue on the aidevops repo
# =============================================================================
# This is the structural enforcement for Option D from GH#5149: a first-class
# action that workers and supervisors can call to route framework observations
# to the correct repo.
#
# Arguments (named):
#   --title "..."    Issue title (required)
#   --body "..."     Issue body (optional, defaults to title)
#   --labels "..."   Comma-separated labels (optional, defaults to "bug")
#   --source-repo "..." The repo where the observation was made (for context)
#
# Returns:
#   0 = issue created (issue URL on stdout)
#   1 = error
#   2 = duplicate found (existing issue URL on stdout)
log_framework_issue() {
	local title="" body="" labels="bug" source_repo=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--title)
			title="$2"
			shift 2
			;;
		--body)
			body="$2"
			shift 2
			;;
		--labels)
			labels="$2"
			shift 2
			;;
		--source-repo)
			source_repo="$2"
			shift 2
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ -z "$title" ]]; then
		log_error "Missing required --title"
		return 1
	fi

	# Resolve aidevops slug
	local slug
	if ! slug=$(get_aidevops_slug); then
		log_error "Cannot resolve aidevops repo slug — cannot create issue"
		return 1
	fi

	# Check gh CLI
	if ! command -v gh &>/dev/null; then
		log_error "gh CLI not available — cannot create issue"
		return 1
	fi

	# Dedup: search for existing issues with similar title
	local search_terms
	search_terms=$(printf '%s' "$title" | sed 's/^[a-zA-Z0-9_-]*: *//')
	if [[ -n "$search_terms" ]]; then
		local existing
		existing=$(gh issue list --repo "$slug" \
			--state open --search "$search_terms" \
			--json number,url --limit 1 -q '.[0].url' 2>/dev/null || echo "")
		if [[ -n "$existing" && "$existing" != "null" ]]; then
			log_info "Duplicate found: $existing"
			echo "$existing"
			return 2
		fi
	fi

	# Build body
	if [[ -z "$body" ]]; then
		body="$title"
	fi

	# Add source context if provided
	if [[ -n "$source_repo" ]]; then
		body="${body}

---
*Detected by framework-routing-helper in \`${source_repo}\`.*"
	fi

	# Append signature footer
	local sig_footer=""
	sig_footer=$("${HOME}/.aidevops/agents/scripts/gh-signature-helper.sh" footer 2>/dev/null || true)
	body="${body}${sig_footer}"

	# Create the issue
	local issue_url
	if ! issue_url=$(gh issue create --repo "$slug" \
		--title "$title" \
		--body "$body" \
		--label "$labels" 2>&1); then
		log_error "Failed to create issue: $issue_url"
		return 1
	fi

	log_success "Framework issue created: $issue_url"
	echo "$issue_url"
	return 0
}

# =============================================================================
# Main dispatch
# =============================================================================
main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	is-framework)
		local description="${1:-}"
		if [[ -z "$description" ]]; then
			log_error "Usage: framework-routing-helper.sh is-framework \"task description\""
			exit 1
		fi
		is_framework_task "$description"
		;;
	get-aidevops-path)
		get_aidevops_path
		;;
	get-aidevops-slug)
		get_aidevops_slug
		;;
	log-framework-issue)
		log_framework_issue "$@"
		;;
	help | --help | -h)
		cat <<'EOF'
framework-routing-helper.sh - Detect and route framework-level tasks

Commands:
  is-framework "desc"     Detect if a task is framework-level
                          Exit: 0=framework, 1=project, 2=uncertain
  get-aidevops-path       Resolve local path to aidevops repo
  get-aidevops-slug       Resolve GitHub slug for aidevops repo
  log-framework-issue     Create an issue on the aidevops repo
    --title "..."         Issue title (required)
    --body "..."          Issue body (optional)
    --labels "..."        Labels (optional, default: bug)
    --source-repo "..."   Source repo for context (optional)

Examples:
  # Check if a task is framework-level
  framework-routing-helper.sh is-framework "fix pulse-wrapper dispatch logic"

  # Log a framework issue from a project repo
  framework-routing-helper.sh log-framework-issue \
    --title "bug: supervisor pipeline stdin consumption" \
    --body "Observed in project repo during pulse dispatch..." \
    --source-repo "myorg/myproject"
EOF
		;;
	*)
		log_error "Unknown command: $command"
		log_error "Run: framework-routing-helper.sh help"
		exit 1
		;;
	esac
}

main "$@"
