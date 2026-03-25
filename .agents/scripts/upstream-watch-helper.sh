#!/usr/bin/env bash
# upstream-watch-helper.sh — Track external repos for release monitoring (t1426)
#
# Maintains a watchlist of external repos we've borrowed ideas/code from.
# Checks for new releases and significant commits, shows changelog diffs
# between our last-seen version and latest. Distinct from:
#   - skill-sources.json (imported skills — tracked by add-skill-helper.sh)
#   - contribution-watch (repos we've contributed to)
#
# This covers "inspiration repos" — repos we want to passively monitor
# for improvements relevant to our implementation.
#
# Usage:
#   upstream-watch-helper.sh add <owner/repo> [--relevance "why we care"]
#   upstream-watch-helper.sh remove <owner/repo>
#   upstream-watch-helper.sh check [--verbose]     Check all watched repos for updates
#   upstream-watch-helper.sh check <owner/repo>    Check a specific repo
#   upstream-watch-helper.sh ack <owner/repo>      Acknowledge latest release (mark as seen)
#   upstream-watch-helper.sh status                Show all watched repos and their state
#   upstream-watch-helper.sh help                  Show usage
#
# Config: ~/.aidevops/agents/configs/upstream-watch.json (template committed)
# State:  ~/.aidevops/cache/upstream-watch-state.json (runtime, gitignored)
# Log:    ~/.aidevops/logs/upstream-watch.log

set -euo pipefail

# PATH normalisation for launchd/MCP environments
export PATH="/bin:/usr/bin:/usr/local/bin:/opt/homebrew/bin:${PATH}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1

# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh" 2>/dev/null || true

# Fallback colours if shared-constants.sh not loaded
[[ -z "${RED+x}" ]] && RED='\033[0;31m'
[[ -z "${GREEN+x}" ]] && GREEN='\033[0;32m'
[[ -z "${YELLOW+x}" ]] && YELLOW='\033[1;33m'
[[ -z "${BLUE+x}" ]] && BLUE='\033[0;34m'
[[ -z "${CYAN+x}" ]] && CYAN='\033[0;36m'
[[ -z "${NC+x}" ]] && NC='\033[0m'

# =============================================================================
# Configuration
# =============================================================================

AGENTS_DIR="${AIDEVOPS_AGENTS_DIR:-$HOME/.aidevops/agents}"
CONFIG_FILE="${AGENTS_DIR}/configs/upstream-watch.json"
STATE_FILE="${HOME}/.aidevops/cache/upstream-watch-state.json"
LOGFILE="${HOME}/.aidevops/logs/upstream-watch.log"

# Logging prefix for shared log_* functions
# shellcheck disable=SC2034
LOG_PREFIX="upstream-watch"

# =============================================================================
# Logging (standalone — shared-constants.sh log_* may not be available)
# =============================================================================

#######################################
# Write a timestamped log entry to the upstream-watch log file
# Arguments:
#   $1 - Log level (INFO, WARN, ERROR)
#   $@ - Log message
#######################################
_log() {
	local level="$1"
	shift
	local msg="$*"
	local timestamp
	timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	local log_dir
	log_dir=$(dirname "$LOGFILE")
	mkdir -p "$log_dir" 2>/dev/null || true
	echo "[${timestamp}] [${level}] ${msg}" >>"$LOGFILE"
	return 0
}

#######################################
# Log an informational message
#######################################
_log_info() {
	_log "INFO" "$@"
	return 0
}

#######################################
# Log a warning message
#######################################
_log_warn() {
	_log "WARN" "$@"
	return 0
}

#######################################
# Log an error message
#######################################
_log_error() {
	_log "ERROR" "$@"
	return 0
}

# =============================================================================
# Prerequisites
# =============================================================================

#######################################
# Verify required tools (gh, jq) are installed and gh is authenticated
# Returns: 0 if all prerequisites met, 1 otherwise
#######################################
_check_prerequisites() {
	if ! command -v gh &>/dev/null; then
		echo -e "${RED}Error: gh CLI not found. Install from https://cli.github.com/${NC}" >&2
		return 1
	fi
	if ! command -v jq &>/dev/null; then
		echo -e "${RED}Error: jq not found. Install with: brew install jq${NC}" >&2
		return 1
	fi
	if ! gh auth status &>/dev/null; then
		echo -e "${RED}Error: gh not authenticated. Run: gh auth login${NC}" >&2
		return 1
	fi
	return 0
}

# =============================================================================
# State file management
# =============================================================================

#######################################
# Create the state file with empty defaults if it doesn't exist
#######################################
_ensure_state_file() {
	local state_dir
	state_dir=$(dirname "$STATE_FILE")
	mkdir -p "$state_dir" 2>/dev/null || true

	if [[ ! -f "$STATE_FILE" ]]; then
		echo '{"last_check":"","repos":{},"non_github":{}}' >"$STATE_FILE"
		_log_info "Created new state file: $STATE_FILE"
	fi
	# Migrate existing state files that lack the non_github key
	if ! jq -e '.non_github' "$STATE_FILE" >/dev/null 2>&1; then
		local migrated
		migrated=$(jq '. + {non_github: {}}' "$STATE_FILE")
		echo "$migrated" >"$STATE_FILE"
	fi
	return 0
}

#######################################
# Read and output the current state JSON
#######################################
_read_state() {
	_ensure_state_file
	cat "$STATE_FILE"
	return 0
}

#######################################
# Write state JSON to the state file, validating JSON first
# Arguments:
#   $1 - JSON string to write
#######################################
_write_state() {
	local state="$1"
	_ensure_state_file
	local jq_err
	jq_err=$(echo "$state" | jq '.' 2>&1 >"$STATE_FILE") || {
		_log_error "Failed to write state file (invalid JSON): ${jq_err}"
		return 1
	}
	return 0
}

# =============================================================================
# Config file management
# =============================================================================

#######################################
# Create the config file with empty defaults if it doesn't exist
#######################################
_ensure_config_file() {
	local config_dir
	config_dir=$(dirname "$CONFIG_FILE")
	mkdir -p "$config_dir" 2>/dev/null || true

	if [[ ! -f "$CONFIG_FILE" ]]; then
		cat >"$CONFIG_FILE" <<'DEFAULTCONFIG'
{
  "$comment": "Upstream repos to watch for releases and significant changes. Managed by upstream-watch-helper.sh.",
  "repos": []
}
DEFAULTCONFIG
		_log_info "Created new config file: $CONFIG_FILE"
	fi
	return 0
}

#######################################
# Read and output the current config JSON
#######################################
_read_config() {
	_ensure_config_file
	cat "$CONFIG_FILE"
	return 0
}

#######################################
# Write config JSON to the config file, validating JSON first
# Arguments:
#   $1 - JSON string to write
#######################################
_write_config() {
	local config="$1"
	_ensure_config_file
	local jq_err
	jq_err=$(echo "$config" | jq '.' 2>&1 >"$CONFIG_FILE") || {
		_log_error "Failed to write config file (invalid JSON): ${jq_err}"
		return 1
	}
	return 0
}

# =============================================================================
# ISO 8601 helpers
# =============================================================================

#######################################
# Output the current UTC time in ISO 8601 format
#######################################
_now_iso() {
	date -u +%Y-%m-%dT%H:%M:%SZ
	return 0
}

# =============================================================================
# Commands
# =============================================================================

#######################################
# Add a repository to the upstream watchlist
# Verifies the repo exists, captures initial state (latest release/commit),
# and stores config + state so the first check doesn't flag everything as new.
# Arguments:
#   $1 - Repository slug (owner/repo)
#   $2 - Optional relevance description
#######################################
cmd_add() {
	local slug="$1"
	local relevance="${2:-}"

	if [[ -z "$slug" ]]; then
		echo -e "${RED}Error: Repository slug required (owner/repo)${NC}" >&2
		return 1
	fi

	# Validate slug format
	if [[ ! "$slug" =~ ^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$ ]]; then
		echo -e "${RED}Error: Invalid slug format. Expected: owner/repo${NC}" >&2
		return 1
	fi

	_check_prerequisites || return 1

	# Check if already watched
	local config
	config=$(_read_config)
	local existing
	existing=$(echo "$config" | jq -r --arg slug "$slug" '.repos[] | select(.slug == $slug) | .slug')
	if [[ -n "$existing" ]]; then
		echo -e "${YELLOW}Already watching: ${slug}${NC}"
		return 0
	fi

	# Verify repo exists and get metadata
	echo -e "${BLUE}Verifying repo: ${slug}...${NC}"
	local repo_info repo_err
	repo_err=$(gh api "repos/${slug}" --jq '{description, stargazers_count, pushed_at, default_branch}' 2>&1) && repo_info="$repo_err" || {
		echo -e "${RED}Error: Could not access repo ${slug}: ${repo_err}${NC}" >&2
		return 1
	}

	local description default_branch
	description=$(echo "$repo_info" | jq -r '.description // "No description"')
	default_branch=$(echo "$repo_info" | jq -r '.default_branch // "main"')

	# Get latest release (if any)
	local latest_release latest_tag
	latest_release=$(gh api "repos/${slug}/releases/latest" --jq '{tag_name, published_at, name}' 2>/dev/null) || latest_release=""
	if [[ -n "$latest_release" ]]; then
		latest_tag=$(echo "$latest_release" | jq -r '.tag_name')
	else
		latest_tag=""
	fi

	# Get latest commit SHA
	local latest_commit
	latest_commit=$(gh api "repos/${slug}/commits?per_page=1" --jq '.[0].sha // empty' 2>/dev/null) || latest_commit=""

	# Build the entry
	local now
	now=$(_now_iso)
	local new_entry
	new_entry=$(jq -n \
		--arg slug "$slug" \
		--arg desc "$description" \
		--arg relevance "$relevance" \
		--arg branch "$default_branch" \
		--arg added "$now" \
		'{
			slug: $slug,
			description: $desc,
			relevance: $relevance,
			default_branch: $branch,
			added_at: $added
		}')

	# Add to config
	config=$(echo "$config" | jq --argjson entry "$new_entry" '.repos += [$entry]')
	_write_config "$config"

	# Set initial state (so first check doesn't flag everything as new)
	local state
	state=$(_read_state)
	local state_entry
	state_entry=$(jq -n \
		--arg tag "$latest_tag" \
		--arg commit "${latest_commit:0:7}" \
		--arg checked "$now" \
		'{
			last_release_seen: $tag,
			last_commit_seen: $commit,
			last_checked: $checked,
			updates_pending: 0
		}')
	state=$(echo "$state" | jq --arg slug "$slug" --argjson entry "$state_entry" '.repos[$slug] = $entry')
	_write_state "$state"

	echo -e "${GREEN}Now watching: ${slug}${NC}"
	echo "  Description: ${description}"
	[[ -n "$relevance" ]] && echo "  Relevance:   ${relevance}"
	[[ -n "$latest_tag" ]] && echo "  Latest release: ${latest_tag}"
	echo "  Default branch: ${default_branch}"
	_log_info "Added watch: ${slug} (relevance: ${relevance:-none})"
	return 0
}

#######################################
# Remove a repository from the upstream watchlist and clean up its state
# Arguments:
#   $1 - Repository slug (owner/repo)
#######################################
cmd_remove() {
	local slug="$1"

	if [[ -z "$slug" ]]; then
		echo -e "${RED}Error: Repository slug required (owner/repo)${NC}" >&2
		return 1
	fi

	local config
	config=$(_read_config)
	local existing
	existing=$(echo "$config" | jq -r --arg slug "$slug" '.repos[] | select(.slug == $slug) | .slug')
	if [[ -z "$existing" ]]; then
		echo -e "${YELLOW}Not watching: ${slug}${NC}"
		return 0
	fi

	config=$(echo "$config" | jq --arg slug "$slug" '.repos = [.repos[] | select(.slug != $slug)]')
	_write_config "$config"

	# Remove from state
	local state
	state=$(_read_state)
	state=$(echo "$state" | jq --arg slug "$slug" 'del(.repos[$slug])')
	_write_state "$state"

	echo -e "${GREEN}Removed: ${slug}${NC}"
	_log_info "Removed watch: ${slug}"
	return 0
}

#######################################
# Report update status for a single GitHub repo and update shared counters.
# Arguments:
#   $1 - slug
#   $2 - relevance
#   $3 - has_new_release (true/false)
#   $4 - has_new_commits (true/false)
#   $5 - last_release_seen
#   $6 - last_commit_seen
#   $7 - latest_release_tag
#   $8 - latest_release_name
#   $9 - latest_release_date
#   $10 - latest_commit (full SHA)
#   $11 - latest_commit_date
#   $12 - verbose (true/false)
# Side-effects: increments _check_updates_found
#######################################
_report_github_repo_update() {
	local slug="$1"
	local relevance="$2"
	local has_new_release="$3"
	local has_new_commits="$4"
	local last_release_seen="$5"
	local last_commit_seen="$6"
	local latest_release_tag="$7"
	local latest_release_name="$8"
	local latest_release_date="$9"
	local latest_commit="${10}"
	local latest_commit_date="${11}"
	local verbose="${12}"

	if [[ "$has_new_release" == true ]]; then
		_check_updates_found=$((_check_updates_found + 1))
		echo ""
		echo -e "${YELLOW}NEW RELEASE${NC}: ${slug}"
		[[ -n "$relevance" ]] && echo -e "  Relevance: ${CYAN}${relevance}${NC}"
		echo "  Previous:  ${last_release_seen:-none}"
		echo "  Latest:    ${latest_release_tag} (${latest_release_date:-unknown})"
		[[ -n "$latest_release_name" && "$latest_release_name" != "$latest_release_tag" ]] &&
			echo "  Name:      ${latest_release_name}"
		_show_release_diff "$slug" "$last_release_seen" "$latest_release_tag"
		if [[ "$verbose" == true ]]; then
			_show_commit_diff "$slug" "$last_commit_seen" "${latest_commit:0:7}"
		fi
		echo "  Action:    Review changes, then run: upstream-watch-helper.sh ack ${slug}"
	elif [[ "$has_new_commits" == true ]]; then
		_check_updates_found=$((_check_updates_found + 1))
		echo ""
		echo -e "${BLUE}NEW COMMITS${NC}: ${slug} (no new release)"
		[[ -n "$relevance" ]] && echo -e "  Relevance: ${CYAN}${relevance}${NC}"
		if [[ "$verbose" == true ]]; then
			_show_commit_diff "$slug" "$last_commit_seen" "${latest_commit:0:7}"
		else
			echo "  Latest commit: ${latest_commit:0:7} (${latest_commit_date:-unknown})"
			echo "  Action:        Review changes, then run: upstream-watch-helper.sh ack ${slug}"
		fi
	else
		echo -e "${GREEN}Up to date${NC}: ${slug} (${latest_release_tag:-no releases})"
	fi
	return 0
}

#######################################
# Check a single GitHub repo for new releases and commits.
# Updates state in-place (passed by reference via global _check_state).
# Arguments:
#   $1 - Repository slug (owner/repo)
#   $2 - Config JSON
#   $3 - Current ISO timestamp
#   $4 - Verbose flag (true/false)
# Outputs: prints update report to stdout
# Returns: 0 if up to date or updated, 1 if probe failed
# Side-effects: sets _check_updates_found, _check_had_probe_failure globals
#######################################
_check_single_github_repo() {
	local slug="$1"
	local config="$2"
	local now="$3"
	local verbose="$4"

	# Get relevance from config
	local relevance
	relevance=$(echo "$config" | jq -r --arg slug "$slug" '.repos[] | select(.slug == $slug) | .relevance // ""')

	# Get last-seen state
	local last_release_seen last_commit_seen
	last_release_seen=$(echo "$_check_state" | jq -r --arg slug "$slug" '.repos[$slug].last_release_seen // ""')
	last_commit_seen=$(echo "$_check_state" | jq -r --arg slug "$slug" '.repos[$slug].last_commit_seen // ""')

	# --- Check releases ---
	local latest_release_tag="" latest_release_name="" latest_release_date=""
	local release_json=""
	local probe_failed=false
	local api_stderr
	api_stderr=$(mktemp)
	if release_json=$(gh api "repos/${slug}/releases/latest" 2>"$api_stderr"); then
		: # success — release_json has the response
	else
		local release_err
		release_err=$(<"$api_stderr")
		# 404 = no releases (normal), anything else = real error
		if [[ "$release_err" == *"Not Found"* || "$release_err" == *"404"* ]]; then
			release_json=""
		else
			_log_warn "gh api releases failed for ${slug}: ${release_err}"
			echo -e "${YELLOW}Warning${NC}: Could not fetch releases for ${slug}" >&2
			release_json=""
			probe_failed=true
		fi
	fi
	rm -f "$api_stderr"

	if [[ -n "$release_json" ]]; then
		latest_release_tag=$(echo "$release_json" | jq -r '.tag_name // ""')
		latest_release_name=$(echo "$release_json" | jq -r '.name // ""')
		latest_release_date=$(echo "$release_json" | jq -r '.published_at // ""')
	fi

	local has_new_release=false
	if [[ -n "$latest_release_tag" && "$latest_release_tag" != "$last_release_seen" ]]; then
		has_new_release=true
	fi

	# --- Check commits (even if no new release) ---
	local latest_commit="" latest_commit_date=""
	local commit_json=""
	api_stderr=$(mktemp)
	if commit_json=$(gh api "repos/${slug}/commits?per_page=1" --jq '.[0]' 2>"$api_stderr"); then
		: # success
	else
		local commit_err
		commit_err=$(<"$api_stderr")
		_log_warn "gh api commits failed for ${slug}: ${commit_err}"
		echo -e "${YELLOW}Warning${NC}: Could not fetch commits for ${slug}" >&2
		commit_json=""
		probe_failed=true
	fi
	rm -f "$api_stderr"

	if [[ -n "$commit_json" ]]; then
		latest_commit=$(echo "$commit_json" | jq -r '.sha // ""')
		latest_commit_date=$(echo "$commit_json" | jq -r '.commit.committer.date // ""')
	fi

	local has_new_commits=false
	if [[ -n "$latest_commit" && "${latest_commit:0:7}" != "$last_commit_seen" ]]; then
		has_new_commits=true
	fi

	# --- Report ---
	_report_github_repo_update "$slug" "$relevance" \
		"$has_new_release" "$has_new_commits" \
		"$last_release_seen" "$last_commit_seen" \
		"$latest_release_tag" "$latest_release_name" "$latest_release_date" \
		"$latest_commit" "$latest_commit_date" "$verbose"

	# Update last_checked and updates_pending (but NOT last_release_seen or last_commit_seen — those require explicit ack)
	# Skip state update if probes failed to avoid masking errors as "up to date"
	if [[ "$probe_failed" != true ]]; then
		_check_state=$(echo "$_check_state" | jq --arg slug "$slug" --arg now "$now" \
			--argjson pending "$([[ "$has_new_release" == true || "$has_new_commits" == true ]] && echo 1 || echo 0)" \
			'.repos[$slug].last_checked = $now | .repos[$slug].updates_pending = $pending')
	else
		_check_had_probe_failure=true
	fi
	return 0
}

#######################################
# Check all non-GitHub upstreams (Docker Hub, GitLab, Forgejo, etc.)
# Updates _check_state in-place via global.
# Arguments:
#   $1 - Config JSON
#   $2 - Target name (empty = all)
#   $3 - Current ISO timestamp
# Side-effects: sets _check_updates_found, _check_had_probe_failure globals
#######################################
_check_non_github_upstreams() {
	local config="$1"
	local target_name="$2"
	local now="$3"

	local non_github_names
	if [[ -n "$target_name" ]]; then
		non_github_names="$target_name"
	else
		non_github_names=$(echo "$config" | jq -r '.non_github_upstreams // [] | .[].name')
	fi

	while IFS= read -r entry_name; do
		[[ -z "$entry_name" ]] && continue

		local entry_json
		entry_json=$(echo "$config" | jq --arg name "$entry_name" '.non_github_upstreams[] | select(.name == $name)')

		local check_cmd source_type description relevance entry_url
		check_cmd=$(echo "$entry_json" | jq -r '.check_command // ""')
		source_type=$(echo "$entry_json" | jq -r '.source_type // "unknown"')
		description=$(echo "$entry_json" | jq -r '.description // ""')
		relevance=$(echo "$entry_json" | jq -r '.relevance // ""')
		entry_url=$(echo "$entry_json" | jq -r '.url // ""')

		if [[ -z "$check_cmd" ]]; then
			echo -e "${YELLOW}Warning${NC}: No check_command for ${entry_name}, skipping" >&2
			continue
		fi

		# Get last-seen state
		local last_seen_value
		last_seen_value=$(echo "$_check_state" | jq -r --arg name "$entry_name" '.non_github[$name].last_seen // ""')

		# Run the check command (curl + jq) in a subshell for isolation
		# Note: check_command comes from a committed config file, not user input
		local current_value=""
		local probe_failed=false
		current_value=$(bash -c "$check_cmd" 2>/dev/null) || {
			_log_warn "check_command failed for ${entry_name}"
			echo -e "${YELLOW}Warning${NC}: Could not check ${entry_name} (${source_type})" >&2
			probe_failed=true
		}

		# Trim whitespace
		current_value=$(echo "$current_value" | tr -d '[:space:]')

		local has_update=false
		if [[ "$probe_failed" != true && -n "$current_value" && "$current_value" != "$last_seen_value" ]]; then
			has_update=true
		fi

		if [[ "$has_update" == true ]]; then
			_check_updates_found=$((_check_updates_found + 1))
			echo ""
			echo -e "${YELLOW}UPDATE DETECTED${NC}: ${entry_name} (${source_type})"
			echo "  Description: ${description}"
			[[ -n "$relevance" ]] && echo -e "  Relevance:   ${CYAN}${relevance}${NC}"
			echo "  Previous:    ${last_seen_value:-none}"
			echo "  Current:     ${current_value}"
			[[ -n "$entry_url" ]] && echo "  URL:         ${entry_url}"

			# Show affected files
			local affects
			affects=$(echo "$entry_json" | jq -r '.affects // [] | .[]' 2>/dev/null)
			if [[ -n "$affects" ]]; then
				echo "  Affects:"
				while IFS= read -r affected_file; do
					[[ -n "$affected_file" ]] && echo "    - ${affected_file}"
				done <<<"$affects"
			fi

			echo "  Action:      Review changes, then run: upstream-watch-helper.sh ack ${entry_name}"
		elif [[ "$probe_failed" != true ]]; then
			echo -e "${GREEN}Up to date${NC}: ${entry_name} (${source_type}: ${current_value:-unknown})"
		fi

		# Update state (but not last_seen — that requires explicit ack)
		if [[ "$probe_failed" != true ]]; then
			_check_state=$(echo "$_check_state" | jq --arg name "$entry_name" --arg now "$now" \
				--arg current "$current_value" \
				--argjson pending "$([[ "$has_update" == true ]] && echo 1 || echo 0)" \
				'.non_github[$name].last_checked = $now | .non_github[$name].current_value = $current | .non_github[$name].updates_pending = $pending')
		else
			_check_had_probe_failure=true
		fi

	done <<<"$non_github_names"
	return 0
}

#######################################
# Check watched repos for new releases and commits
# Compares current GitHub state against last-seen state. Reports new
# releases with changelog diffs and new commits. Does NOT advance
# last_seen — that requires explicit ack. Returns 1 if any probe failed.
# Also checks non-GitHub upstreams (Docker Hub, GitLab, Forgejo) via
# their configured check_command.
# Arguments:
#   $1 - Optional target slug/name to check a single repo
# Globals:
#   VERBOSE - Show commit-level detail when true
#######################################
cmd_check() {
	local target_slug="${1:-}"
	local verbose="${VERBOSE:-false}"

	_check_prerequisites || return 1

	local config
	config=$(_read_config)
	# Use a global so sub-functions can update state in-place
	_check_state=$(_read_state)

	# Check if target is a non-GitHub upstream name
	local target_is_non_github=false
	if [[ -n "$target_slug" ]]; then
		if echo "$config" | jq -e --arg name "$target_slug" '.non_github_upstreams // [] | .[] | select(.name == $name)' >/dev/null 2>&1; then
			target_is_non_github=true
		fi
	fi

	local slugs=""
	if [[ -n "$target_slug" && "$target_is_non_github" != true ]]; then
		# Validate that the target slug is on the GitHub watchlist
		if ! echo "$config" | jq -e --arg slug "$target_slug" '.repos[] | select(.slug == $slug)' >/dev/null 2>&1; then
			echo -e "${RED}Error: Not watching ${target_slug}. Add it first with 'upstream-watch-helper.sh add ${target_slug}'.${NC}" >&2
			return 1
		fi
		slugs="$target_slug"
	elif [[ "$target_is_non_github" != true ]]; then
		slugs=$(echo "$config" | jq -r '.repos[].slug')
	fi

	local has_github_repos=false
	local has_non_github=false
	[[ -n "$slugs" ]] && has_github_repos=true
	if echo "$config" | jq -e '.non_github_upstreams // [] | length > 0' >/dev/null 2>&1; then
		has_non_github=true
	fi

	if [[ "$has_github_repos" != true && "$has_non_github" != true ]]; then
		echo -e "${BLUE}No repos being watched. Use 'add' to start watching.${NC}"
		return 0
	fi

	# Shared counters updated by sub-functions
	_check_updates_found=0
	_check_had_probe_failure=false
	local now
	now=$(_now_iso)

	# Check GitHub repos
	while IFS= read -r slug; do
		[[ -z "$slug" ]] && continue
		_check_single_github_repo "$slug" "$config" "$now" "$verbose"
	done <<<"$slugs"

	# Check non-GitHub upstreams
	if [[ "$has_non_github" == true ]]; then
		local ng_target=""
		[[ "$target_is_non_github" == true ]] && ng_target="$target_slug"
		_check_non_github_upstreams "$config" "$ng_target" "$now"
	fi

	# Only advance global last_check if all probes succeeded — partial failures
	# should not advance the 24h gate so the caller retries on the next cycle
	if [[ "$_check_had_probe_failure" != true ]]; then
		_check_state=$(echo "$_check_state" | jq --arg now "$now" '.last_check = $now')
	fi
	_write_state "$_check_state"

	echo ""
	if [[ "$_check_updates_found" -gt 0 ]]; then
		echo -e "${YELLOW}${_check_updates_found} repo(s) have updates to review.${NC}"
	else
		echo -e "${GREEN}All watched repos are up to date.${NC}"
	fi

	_log_info "Check complete: ${_check_updates_found} updates found"
	[[ "$_check_had_probe_failure" == true ]] && return 1
	return 0
}

#######################################
# Display release changelog between two tags
# Shows all releases between from_tag and to_tag, plus latest release notes.
# Arguments:
#   $1 - Repository slug (owner/repo)
#   $2 - From tag (last seen, empty for first check)
#   $3 - To tag (latest release)
#######################################
_show_release_diff() {
	local slug="$1"
	local from_tag="$2"
	local to_tag="$3"

	if [[ -z "$from_tag" ]]; then
		# First time — just show the latest release notes
		echo "  Release notes:"
		local body
		body=$(gh api "repos/${slug}/releases/latest" --jq '.body // "No release notes"' 2>/dev/null) || body="Could not fetch"
		sed -n '1,20{s/^/    /;p;}' <<<"$body"
		local line_count
		line_count=$(wc -l <<<"$body" | tr -d ' ')
		if [[ "$line_count" -gt 20 ]]; then
			echo "    ... (${line_count} lines total — view full notes on GitHub)"
		fi
		return 0
	fi

	# Show all releases between from_tag and to_tag
	local releases
	releases=$(gh api --paginate "repos/${slug}/releases" --jq '.[].tag_name' 2>/dev/null) || {
		echo "  (Could not fetch release list)"
		return 0
	}

	# Find releases newer than from_tag
	local in_range=true
	local release_count=0
	echo "  Releases since ${from_tag}:"
	while IFS= read -r tag; do
		[[ -z "$tag" ]] && continue
		if [[ "$tag" == "$from_tag" ]]; then
			in_range=false
			continue
		fi
		if [[ "$in_range" == true ]]; then
			release_count=$((release_count + 1))
			# Get one-line summary for each release
			local rel_name rel_date
			rel_name=$(gh api "repos/${slug}/releases/tags/${tag}" --jq '.name // .tag_name' 2>/dev/null) || rel_name="$tag"
			rel_date=$(gh api "repos/${slug}/releases/tags/${tag}" --jq '.published_at // ""' 2>/dev/null) || rel_date=""
			local date_short="${rel_date:0:10}"
			echo "    ${tag} (${date_short}) — ${rel_name}"
		fi
	done <<<"$releases"

	if [[ "$release_count" -eq 0 ]]; then
		echo "    (none found — tags may not match release list)"
	fi

	# Show latest release notes
	echo ""
	echo "  Latest release notes (${to_tag}):"
	local body
	body=$(gh api "repos/${slug}/releases/tags/${to_tag}" --jq '.body // "No release notes"' 2>/dev/null) || body="Could not fetch"
	sed -n '1,30{s/^/    /;p;}' <<<"$body"
	local line_count
	line_count=$(wc -l <<<"$body" | tr -d ' ')
	if [[ "$line_count" -gt 30 ]]; then
		echo "    ... (${line_count} lines total)"
	fi
	return 0
}

#######################################
# Display recent commits between two SHAs
# Shows up to 10 commits newer than from_sha.
# Arguments:
#   $1 - Repository slug (owner/repo)
#   $2 - From SHA (7-char, last seen)
#   $3 - To SHA (7-char, latest)
#######################################
_show_commit_diff() {
	local slug="$1"
	local from_sha="$2"
	local to_sha="$3"

	if [[ -z "$from_sha" || "$from_sha" == "$to_sha" ]]; then
		return 0
	fi

	echo "  Recent commits:"
	local commits
	commits=$(gh api "repos/${slug}/commits?per_page=10" \
		--jq '.[] | "\(.sha[0:7]) \(.commit.message | split("\n")[0])"' 2>/dev/null) || {
		echo "    (Could not fetch commits)"
		return 0
	}

	local count=0
	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		local sha="${line%% *}"
		if [[ "$sha" == "$from_sha" ]]; then
			break
		fi
		count=$((count + 1))
		echo "    ${line}"
		if [[ "$count" -ge 10 ]]; then
			echo "    ... (showing first 10)"
			break
		fi
	done <<<"$commits"

	if [[ "$count" -eq 0 ]]; then
		echo "    (no new commits found in recent history)"
	fi
	return 0
}

#######################################
# Acknowledge the latest release/commit for a watched repo
# Updates last_release_seen and last_commit_seen to current, clears
# updates_pending. Validates slug against config watchlist first.
# Arguments:
#   $1 - Repository slug (owner/repo)
#######################################
cmd_ack() {
	local slug="$1"

	if [[ -z "$slug" ]]; then
		echo -e "${RED}Error: Repository slug or upstream name required${NC}" >&2
		return 1
	fi

	local config
	config=$(_read_config)
	local state
	state=$(_read_state)
	local now
	now=$(_now_iso)

	# Check if this is a non-GitHub upstream name
	if echo "$config" | jq -e --arg name "$slug" '.non_github_upstreams // [] | .[] | select(.name == $name)' >/dev/null 2>&1; then
		# Non-GitHub upstream — run check_command to get current value and store as last_seen
		local check_cmd
		check_cmd=$(echo "$config" | jq -r --arg name "$slug" '.non_github_upstreams[] | select(.name == $name) | .check_command // ""')

		local current_value=""
		if [[ -n "$check_cmd" ]]; then
			current_value=$(bash -c "$check_cmd" 2>/dev/null | tr -d '[:space:]') || current_value=""
		fi

		# Also update last_seen_commit in config if the entry has one
		local has_last_seen_commit
		has_last_seen_commit=$(echo "$config" | jq -r --arg name "$slug" '.non_github_upstreams[] | select(.name == $name) | .last_seen_commit // ""')
		if [[ -n "$has_last_seen_commit" ]]; then
			config=$(echo "$config" | jq --arg name "$slug" --arg commit "$current_value" \
				'(.non_github_upstreams[] | select(.name == $name) | .last_seen_commit) = $commit')
			_write_config "$config"
		fi

		state=$(echo "$state" | jq --arg name "$slug" --arg value "$current_value" --arg now "$now" \
			'.non_github[$name].last_seen = $value | .non_github[$name].last_checked = $now | .non_github[$name].updates_pending = 0')
		_write_state "$state"

		echo -e "${GREEN}Acknowledged: ${slug} at ${current_value:-unknown}${NC}"
		_log_info "Acknowledged non-GitHub upstream: ${slug} at ${current_value:-unknown}"
		return 0
	fi

	# GitHub repo — original logic
	_check_prerequisites || return 1

	# Validate against config watchlist (consistent with cmd_check)
	if ! echo "$config" | jq -e --arg slug "$slug" '.repos[] | select(.slug == $slug)' >/dev/null 2>&1; then
		echo -e "${RED}Error: Not watching ${slug}. Add it first with 'upstream-watch-helper.sh add ${slug}'.${NC}" >&2
		return 1
	fi

	# Get current latest release
	local latest_tag
	latest_tag=$(gh api "repos/${slug}/releases/latest" --jq '.tag_name' 2>/dev/null) || latest_tag=""

	local latest_commit
	latest_commit=$(gh api "repos/${slug}/commits?per_page=1" --jq '.[0].sha // empty' 2>/dev/null) || latest_commit=""

	state=$(echo "$state" | jq --arg slug "$slug" --arg tag "$latest_tag" \
		--arg commit "${latest_commit:0:7}" --arg now "$now" \
		'.repos[$slug].last_release_seen = $tag | .repos[$slug].last_commit_seen = $commit | .repos[$slug].last_checked = $now | .repos[$slug].updates_pending = 0')
	_write_state "$state"

	echo -e "${GREEN}Acknowledged: ${slug} at ${latest_tag:-commit ${latest_commit:0:7}}${NC}"
	_log_info "Acknowledged: ${slug} at ${latest_tag:-${latest_commit:0:7}}"
	return 0
}

#######################################
# Display the status of all watched repos
# Shows repo count, last check time, and per-repo state including
# last release/commit seen, last checked date, and pending updates.
#######################################
cmd_status() {
	local config
	config=$(_read_config)
	local state
	state=$(_read_state)

	local repo_count non_github_count
	repo_count=$(echo "$config" | jq '.repos | length')
	non_github_count=$(echo "$config" | jq '.non_github_upstreams // [] | length')
	local total_count=$((repo_count + non_github_count))

	if [[ "$total_count" -eq 0 ]]; then
		echo -e "${BLUE}No repos being watched.${NC}"
		echo ""
		echo "Add repos with: upstream-watch-helper.sh add <owner/repo> --relevance \"why we care\""
		return 0
	fi

	local last_check
	last_check=$(echo "$state" | jq -r '.last_check // "never"')

	echo -e "${BLUE}Upstream Watch Status${NC}"
	echo "GitHub repos:          ${repo_count}"
	echo "Non-GitHub upstreams:  ${non_github_count}"
	echo "Last check:            ${last_check}"
	echo ""

	# GitHub repos
	if [[ "$repo_count" -gt 0 ]]; then
		echo -e "${BLUE}GitHub Repos${NC}"
		echo "$config" | jq -r '.repos[] | .slug' | while IFS= read -r slug; do
			[[ -z "$slug" ]] && continue

			local relevance
			relevance=$(echo "$config" | jq -r --arg slug "$slug" '.repos[] | select(.slug == $slug) | .relevance // ""')
			local last_release last_commit last_checked pending
			last_release=$(echo "$state" | jq -r --arg slug "$slug" '.repos[$slug].last_release_seen // "none"')
			last_commit=$(echo "$state" | jq -r --arg slug "$slug" '.repos[$slug].last_commit_seen // "none"')
			last_checked=$(echo "$state" | jq -r --arg slug "$slug" '.repos[$slug].last_checked // "never"')
			pending=$(echo "$state" | jq -r --arg slug "$slug" '.repos[$slug].updates_pending // 0')

			if [[ "$pending" -gt 0 ]]; then
				echo -e "  ${YELLOW}*${NC} ${slug}"
			else
				echo -e "  ${GREEN}-${NC} ${slug}"
			fi
			echo "    Last release seen: ${last_release}"
			echo "    Last commit seen:  ${last_commit}"
			echo "    Last checked:      ${last_checked:0:10}"
			[[ -n "$relevance" ]] && echo "    Relevance:         ${relevance}"
			echo ""
		done
	fi

	# Non-GitHub upstreams
	if [[ "$non_github_count" -gt 0 ]]; then
		echo -e "${BLUE}Non-GitHub Upstreams${NC}"
		echo "$config" | jq -r '.non_github_upstreams[] | .name' | while IFS= read -r entry_name; do
			[[ -z "$entry_name" ]] && continue

			local source_type description relevance
			source_type=$(echo "$config" | jq -r --arg name "$entry_name" '.non_github_upstreams[] | select(.name == $name) | .source_type // "unknown"')
			description=$(echo "$config" | jq -r --arg name "$entry_name" '.non_github_upstreams[] | select(.name == $name) | .description // ""')
			relevance=$(echo "$config" | jq -r --arg name "$entry_name" '.non_github_upstreams[] | select(.name == $name) | .relevance // ""')

			local last_seen last_checked pending
			last_seen=$(echo "$state" | jq -r --arg name "$entry_name" '.non_github[$name].last_seen // "none"')
			last_checked=$(echo "$state" | jq -r --arg name "$entry_name" '.non_github[$name].last_checked // "never"')
			pending=$(echo "$state" | jq -r --arg name "$entry_name" '.non_github[$name].updates_pending // 0')

			if [[ "$pending" -gt 0 ]]; then
				echo -e "  ${YELLOW}*${NC} ${entry_name} (${source_type})"
			else
				echo -e "  ${GREEN}-${NC} ${entry_name} (${source_type})"
			fi
			echo "    Description:  ${description}"
			echo "    Last seen:    ${last_seen}"
			echo "    Last checked: ${last_checked:0:10}"
			[[ -n "$relevance" ]] && echo "    Relevance:    ${relevance}"
			echo ""
		done
	fi

	return 0
}

#######################################
# Display usage information and examples
#######################################
cmd_help() {
	cat <<'EOF'
upstream-watch-helper.sh — Track external repos for release monitoring

USAGE:
    upstream-watch-helper.sh <command> [options]

COMMANDS:
    add <owner/repo> [--relevance "..."]   Add a repo to the watchlist
    remove <owner/repo>                     Remove a repo from the watchlist
    check [--verbose]                       Check all repos for new releases/commits
    check <owner/repo>                      Check a specific repo
    ack <owner/repo>                        Mark latest release as seen
    status                                  Show all watched repos and their state
    help                                    Show this help

EXAMPLES:
    # Watch a repo
    upstream-watch-helper.sh add vercel-labs/portless \
      --relevance "Local dev hosting — compare against localdev-helper.sh"

    # Check for updates
    upstream-watch-helper.sh check
    upstream-watch-helper.sh check --verbose    # Include commit-level detail

    # After reviewing, acknowledge the update
    upstream-watch-helper.sh ack vercel-labs/portless

    # See what we're watching
    upstream-watch-helper.sh status

CONFIG:
    Watchlist: ~/.aidevops/agents/configs/upstream-watch.json
    State:     ~/.aidevops/cache/upstream-watch-state.json
    Log:       ~/.aidevops/logs/upstream-watch.log

NON-GITHUB UPSTREAMS:
    Repos on Docker Hub, GitLab, Forgejo, etc. are configured in
    upstream-watch.json under "non_github_upstreams". Each entry has
    a "check_command" (curl + jq) that returns the current version
    or commit SHA. Use the entry "name" for check/ack commands:

    upstream-watch-helper.sh check cloudron-base-image
    upstream-watch-helper.sh ack cloudron-official-skills

INTEGRATION:
    The pulse can call 'upstream-watch-helper.sh check' to surface
    updates during supervisor sweeps. New releases appear as
    informational items for human review. Both GitHub repos and
    non-GitHub upstreams are checked in a single pass.

    Skill imports (skill-sources.json) are tracked separately by
    add-skill-helper.sh. This tool is for repos we haven't imported
    from but want to monitor for ideas and improvements.
EOF
	return 0
}

# =============================================================================
# Main dispatch
# =============================================================================

#######################################
# Main entry point — parse command and dispatch to handler
# Arguments:
#   $1 - Command (add, remove, check, ack, status, help)
#   $@ - Command-specific arguments
#######################################
main() {
	local cmd="${1:-help}"
	shift || true

	case "$cmd" in
	add)
		local slug=""
		local relevance=""
		while [[ $# -gt 0 ]]; do
			case "$1" in
			--relevance)
				if [[ $# -ge 2 && -n "${2:-}" && "${2:0:1}" != "-" ]]; then
					relevance="$2"
					shift 2
				else
					echo -e "${RED}Error: --relevance requires a value${NC}" >&2
					return 1
				fi
				;;
			*)
				if [[ -z "$slug" ]]; then
					slug="$1"
				fi
				shift
				;;
			esac
		done
		cmd_add "$slug" "$relevance"
		;;
	remove | rm)
		cmd_remove "${1:-}"
		;;
	check)
		local target=""
		local verbose=false
		while [[ $# -gt 0 ]]; do
			case "$1" in
			--verbose | -v)
				verbose=true
				shift
				;;
			*)
				target="$1"
				shift
				;;
			esac
		done
		VERBOSE="$verbose" cmd_check "$target"
		;;
	ack | acknowledge)
		cmd_ack "${1:-}"
		;;
	status | list)
		cmd_status
		;;
	help | --help | -h)
		cmd_help
		;;
	*)
		echo -e "${RED}Unknown command: ${cmd}${NC}" >&2
		echo "Run 'upstream-watch-helper.sh help' for usage." >&2
		return 1
		;;
	esac
}

main "$@"
