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
	printf '[%s] [skill-update] [%s] %s\n' "$timestamp" "$level" "$*" >>"$SKILL_LOG_FILE"
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

# Fetch a URL and compute its SHA-256 content hash.
# Downloads to a temp file first so we can detect fetch failures separately
# from hash computation (piping curl|shasum loses the curl exit code with
# pipefail, and produces a hash of empty input on failure).
# Arguments:
#   $1 - URL to fetch
# Outputs: hex-encoded SHA-256 hash of the response body
# Returns: 0 on success, 1 on fetch failure or empty response
fetch_url_hash() {
	local url="$1"

	local tmp_file
	tmp_file=$(mktemp)
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "rm -f '${tmp_file}'"

	# Download to temp file — -f fails on HTTP errors, -L follows redirects
	if ! curl -sS --connect-timeout 15 --max-time 60 \
		-L -f -o "$tmp_file" "$url" 2>/dev/null; then
		return 1
	fi

	# Reject empty responses (server returned 200 but no body)
	if [[ ! -s "$tmp_file" ]]; then
		return 1
	fi

	local hash
	hash=$(shasum -a 256 "$tmp_file" | cut -d' ' -f1)

	if [[ -z "$hash" ]]; then
		return 1
	fi

	echo "$hash"
	return 0
}

# Fetch a URL with conditional request headers (ETag/Last-Modified) to avoid
# re-downloading unchanged content (t1415.3). Returns "not_modified" on HTTP 304,
# or the SHA-256 hash on HTTP 200. Also captures response ETag and Last-Modified
# headers into global variables for the caller to store.
#
# Arguments:
#   $1 - URL to fetch
#   $2 - stored ETag value (may be empty)
#   $3 - stored Last-Modified value (may be empty)
# Outputs: "not_modified" on 304, or hex-encoded SHA-256 hash on 200
# Side effects: sets FETCH_RESP_ETAG and FETCH_RESP_LAST_MODIFIED globals
# Returns: 0 on success (200 or 304), 1 on fetch failure or empty response
FETCH_RESP_ETAG=""
FETCH_RESP_LAST_MODIFIED=""

fetch_url_conditional() {
	local url="$1"
	local stored_etag="${2:-}"
	local stored_last_modified="${3:-}"

	# Reset response header globals
	FETCH_RESP_ETAG=""
	FETCH_RESP_LAST_MODIFIED=""

	local tmp_file header_file
	tmp_file=$(mktemp)
	header_file=$(mktemp)
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "rm -f '${tmp_file}'"
	push_cleanup "rm -f '${header_file}'"

	# Build curl args with conditional headers
	local curl_args=(-sS --connect-timeout 15 --max-time 60 -L
		-o "$tmp_file" -D "$header_file"
		-w "%{http_code}")

	if [[ -n "$stored_etag" ]]; then
		curl_args+=(-H "If-None-Match: ${stored_etag}")
	fi
	if [[ -n "$stored_last_modified" ]]; then
		curl_args+=(-H "If-Modified-Since: ${stored_last_modified}")
	fi

	local http_code
	http_code=$(curl "${curl_args[@]}" "$url" 2>/dev/null) || {
		return 1
	}

	# Parse response headers (case-insensitive, handle \r line endings)
	if [[ -f "$header_file" ]]; then
		FETCH_RESP_ETAG=$(grep -i '^etag:' "$header_file" | tail -1 | sed 's/^[Ee][Tt][Aa][Gg]: *//; s/\r$//')
		FETCH_RESP_LAST_MODIFIED=$(grep -i '^last-modified:' "$header_file" | tail -1 | sed 's/^[Ll][Aa][Ss][Tt]-[Mm][Oo][Dd][Ii][Ff][Ii][Ee][Dd]: *//; s/\r$//')
	fi

	# HTTP 304 Not Modified — content unchanged, no need to re-download
	if [[ "$http_code" == "304" ]]; then
		echo "not_modified"
		return 0
	fi

	# Non-2xx responses are failures (except 304 handled above)
	if [[ "${http_code:0:1}" != "2" ]]; then
		return 1
	fi

	# Reject empty responses
	if [[ ! -s "$tmp_file" ]]; then
		return 1
	fi

	local hash
	hash=$(shasum -a 256 "$tmp_file" | cut -d' ' -f1)

	if [[ -z "$hash" ]]; then
		return 1
	fi

	echo "$hash"
	return 0
}

# Update the upstream_hash field in skill-sources.json for a URL-sourced skill.
# Arguments:
#   $1 - skill name
#   $2 - new hash value
# Returns: 0 on success
update_upstream_hash() {
	local skill_name="$1"
	local new_hash="$2"

	local tmp_file
	tmp_file=$(mktemp)
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "rm -f '${tmp_file}'"

	jq --arg name "$skill_name" --arg hash "$new_hash" \
		'.skills = [.skills[] | if .name == $name then .upstream_hash = $hash else . end]' \
		"$SKILL_SOURCES" >"$tmp_file" && mv "$tmp_file" "$SKILL_SOURCES"
	return 0
}

# Update ETag and Last-Modified cache headers in skill-sources.json (t1415.3).
# Stores HTTP caching headers so subsequent checks can use conditional requests
# (If-None-Match / If-Modified-Since) to avoid re-downloading unchanged content.
# Arguments:
#   $1 - skill name
#   $2 - ETag value (may be empty)
#   $3 - Last-Modified value (may be empty)
# Returns: 0 on success
update_cache_headers() {
	local skill_name="$1"
	local etag="${2:-}"
	local last_modified="${3:-}"

	# Skip if neither header is available
	if [[ -z "$etag" && -z "$last_modified" ]]; then
		return 0
	fi

	local tmp_file
	tmp_file=$(mktemp)
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "rm -f '${tmp_file}'"

	jq --arg name "$skill_name" --arg etag "$etag" --arg lm "$last_modified" \
		'.skills = [.skills[] | if .name == $name then
			(if $etag != "" then .upstream_etag = $etag else . end) |
			(if $lm != "" then .upstream_last_modified = $lm else . end)
		else . end]' \
		"$SKILL_SOURCES" >"$tmp_file" && mv "$tmp_file" "$SKILL_SOURCES"
	return 0
}

# Check if a skill uses URL-based tracking (format_detected == "url").
# Arguments:
#   $1 - skill JSON object (from jq -c)
# Returns: 0 if URL-sourced, 1 otherwise
is_url_skill() {
	local skill_json="$1"
	local format
	format=$(echo "$skill_json" | jq -r '.format_detected // empty')
	if [[ "$format" == "url" ]]; then
		return 0
	fi
	return 1
}

# =============================================================================
# Commands
# =============================================================================

# Check a URL-sourced skill for updates. Populates the caller's counters and
# results array via indirect side-effects on the named variables passed in.
# Arguments:
#   $1 - skill JSON object (from jq -c)
#   $2 - skill name
#   $3 - upstream URL
# Outputs: nothing directly; caller reads updates_available/up_to_date/check_failed/results
# Returns: 0 to continue loop, 1 to signal check_failed (caller increments)
_check_url_skill() {
	local skill_json="$1"
	local name="$2"
	local upstream_url="$3"

	local stored_hash stored_etag stored_last_modified
	stored_hash=$(echo "$skill_json" | jq -r '.upstream_hash // empty')
	stored_etag=$(echo "$skill_json" | jq -r '.upstream_etag // empty')
	stored_last_modified=$(echo "$skill_json" | jq -r '.upstream_last_modified // empty')

	local latest_hash
	if ! latest_hash=$(fetch_url_conditional "$upstream_url" "$stored_etag" "$stored_last_modified"); then
		log_warning "Could not fetch URL for $name: $upstream_url"
		return 1
	fi

	# Store updated cache headers from the response
	update_cache_headers "$name" "$FETCH_RESP_ETAG" "$FETCH_RESP_LAST_MODIFIED"

	# HTTP 304 — content unchanged, skip hash computation entirely
	if [[ "$latest_hash" == "not_modified" ]]; then
		update_last_checked "$name"
		if [[ "$NON_INTERACTIVE" != true ]]; then
			echo -e "${GREEN}Up to date${NC}: $name (304 Not Modified)"
		fi
		log_info "Up to date: $name (304 Not Modified, skipped download)"
		((++up_to_date))
		results+=("{\"name\":\"$name\",\"status\":\"up_to_date\",\"commit\":\"${stored_hash}\"}")
		return 0
	fi

	# Update last_checked timestamp
	update_last_checked "$name"

	if [[ -z "$stored_hash" ]]; then
		if [[ "$NON_INTERACTIVE" != true ]]; then
			echo -e "${YELLOW}UNKNOWN${NC}: $name (no hash recorded)"
			echo "  Source: $upstream_url"
			echo "  Latest hash: ${latest_hash:0:12}"
			echo ""
		fi
		log_info "UNKNOWN: $name (no hash recorded) latest_hash=${latest_hash:0:12}"
		((++updates_available))
		results+=("{\"name\":\"$name\",\"status\":\"unknown\",\"latest\":\"${latest_hash}\"}")
	elif [[ "$latest_hash" != "$stored_hash" ]]; then
		if [[ "$NON_INTERACTIVE" != true ]]; then
			echo -e "${YELLOW}UPDATE AVAILABLE${NC}: $name (URL content changed)"
			echo "  Previous hash: ${stored_hash:0:12}"
			echo "  Current hash:  ${latest_hash:0:12}"
			echo "  Run: aidevops skill update $name"
			echo ""
		fi
		log_info "UPDATE AVAILABLE: $name prev_hash=${stored_hash:0:12} new_hash=${latest_hash:0:12}"
		((++updates_available))
		results+=("{\"name\":\"$name\",\"status\":\"update_available\",\"current\":\"${stored_hash}\",\"latest\":\"${latest_hash}\"}")
		if [[ "$AUTO_UPDATE" == true ]]; then
			log_info "Auto-updating $name..."
			local add_exit=0
			if [[ "$NON_INTERACTIVE" == true ]]; then
				"$ADD_SKILL_HELPER" add "$upstream_url" --force </dev/null >>"$SKILL_LOG_FILE" 2>&1 || add_exit=$?
			else
				"$ADD_SKILL_HELPER" add "$upstream_url" --force || add_exit=$?
			fi
			if [[ "$add_exit" -eq 0 ]]; then
				update_upstream_hash "$name" "$latest_hash"
				log_success "Updated $name"
			else
				log_error "Failed to update $name (exit $add_exit)"
			fi
		fi
	else
		if [[ "$NON_INTERACTIVE" != true ]]; then
			echo -e "${GREEN}Up to date${NC}: $name"
		fi
		log_info "Up to date: $name hash=${stored_hash:0:12}"
		((++up_to_date))
		results+=("{\"name\":\"$name\",\"status\":\"up_to_date\",\"commit\":\"${stored_hash}\"}")
	fi
	return 0
}

# Check a GitHub-sourced skill for updates. Populates the caller's counters and
# results array via indirect side-effects on the named variables passed in.
# Arguments:
#   $1 - skill name
#   $2 - upstream URL
#   $3 - current commit SHA (may be empty)
# Returns: 0 to continue loop, 1 to signal check_failed (caller increments)
_check_github_skill() {
	local name="$1"
	local upstream_url="$2"
	local current_commit="$3"

	local owner_repo
	owner_repo=$(parse_github_url "$upstream_url")
	owner_repo=$(echo "$owner_repo" | cut -d'/' -f1-2)

	if [[ -z "$owner_repo" || "$owner_repo" == "/" ]]; then
		log_warning "Could not parse URL for $name: $upstream_url"
		return 1
	fi

	local latest_commit
	if ! latest_commit=$(get_latest_commit "$owner_repo"); then
		log_warning "Could not fetch latest commit for $name ($owner_repo)"
		return 1
	fi

	update_last_checked "$name"

	if [[ -z "$current_commit" ]]; then
		if [[ "$NON_INTERACTIVE" != true ]]; then
			echo -e "${YELLOW}UNKNOWN${NC}: $name (no commit recorded)"
			echo "  Source: $upstream_url"
			echo "  Latest: ${latest_commit:0:7}"
			echo ""
		fi
		log_info "UNKNOWN: $name (no commit recorded) latest=${latest_commit:0:7}"
		((++updates_available))
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
		((++updates_available))
		results+=("{\"name\":\"$name\",\"status\":\"update_available\",\"current\":\"$current_commit\",\"latest\":\"$latest_commit\"}")
		if [[ "$AUTO_UPDATE" == true ]]; then
			log_info "Auto-updating $name..."
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
		((++up_to_date))
		results+=("{\"name\":\"$name\",\"status\":\"up_to_date\",\"commit\":\"$current_commit\"}")
	fi
	return 0
}

# Print the check summary (human-readable + optional JSON).
# Reads from caller's up_to_date/updates_available/check_failed/results variables.
# Returns: 0 if no updates, 1 if updates available
_print_check_summary() {
	local up_to_date="$1"
	local updates_available="$2"
	local check_failed="$3"
	shift 3
	local results=("$@")

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

	if [[ "$JSON_OUTPUT" == true ]]; then
		echo ""
		echo "{"
		echo "  \"up_to_date\": $up_to_date,"
		echo "  \"updates_available\": $updates_available,"
		echo "  \"check_failed\": $check_failed,"
		local results_json
		results_json=$(printf '%s,' "${results[@]}")
		results_json="${results_json%,}"
		echo "  \"results\": [$results_json]"
		echo "}"
	fi

	if [[ $updates_available -gt 0 ]]; then
		return 1
	fi
	return 0
}

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

	while IFS= read -r skill_json; do
		local name upstream_url current_commit
		name=$(echo "$skill_json" | jq -r '.name')
		upstream_url=$(echo "$skill_json" | jq -r '.upstream_url')
		current_commit=$(echo "$skill_json" | jq -r '.upstream_commit // empty')

		if is_url_skill "$skill_json"; then
			if ! _check_url_skill "$skill_json" "$name" "$upstream_url"; then
				((++check_failed))
			fi
			continue
		fi

		if ! _check_github_skill "$name" "$upstream_url" "$current_commit"; then
			((++check_failed))
		fi

	done < <(jq -c '.skills[]' "$SKILL_SOURCES")

	_print_check_summary "$up_to_date" "$updates_available" "$check_failed" "${results[@]+"${results[@]}"}"
	return $?
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

		# For URL-sourced skills, update the stored hash and cache headers after re-import (t1415.2, t1415.3)
		local format
		format=$(jq -r --arg name "$skill_name" '.skills[] | select(.name == $name) | .format_detected // empty' "$SKILL_SOURCES")
		if [[ "$format" == "url" ]]; then
			local new_hash
			if new_hash=$(fetch_url_conditional "$upstream_url" "" ""); then
				if [[ "$new_hash" != "not_modified" ]]; then
					update_upstream_hash "$skill_name" "$new_hash"
					log_info "Updated upstream_hash for $skill_name"
				fi
				update_cache_headers "$skill_name" "$FETCH_RESP_ETAG" "$FETCH_RESP_LAST_MODIFIED"
			fi
		fi
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
                upstream_hash: (.upstream_hash // null),
                upstream_etag: (.upstream_etag // null),
                upstream_last_modified: (.upstream_last_modified // null),
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

	jq -r '.skills[] | "  \(.name)\n    Path: \(.local_path)\n    Source: \(.upstream_url)\n    Format: \(.format_detected)\(if .format_detected == "url" then "\n    Hash: \(.upstream_hash // "none")\(if .upstream_etag then "\n    ETag: \(.upstream_etag)" else "" end)\(if .upstream_last_modified then "\n    Last-Modified: \(.upstream_last_modified)" else "" end)" else "" end)\n    Imported: \(.imported_at)\n    Last checked: \(.last_checked // "never")\n    Strategy: \(.merge_strategy)\n"' "$SKILL_SOURCES"

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
	# shellcheck disable=SC2016 # backticks are literal markdown, not command substitution
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

# Generate a conventional commit message for a URL-sourced skill update (t1415.2).
# Arguments:
#   $1 - skill name
#   $2 - upstream URL
#   $3 - previous hash (may be empty)
#   $4 - new hash
# Outputs: commit message string
# Returns: 0 always
generate_url_skill_commit_msg() {
	local skill_name="$1"
	local upstream_url="$2"
	local prev_hash="$3"
	local new_hash="$4"

	local timestamp
	timestamp=$(date -u +"%Y-%m-%d")

	local subject="chore(skill/${skill_name}): update from upstream URL (${new_hash:0:12})"

	local prev_short="${prev_hash:0:12}"
	[[ -z "$prev_short" ]] && prev_short="(none)"

	local body
	body="Upstream: ${upstream_url}
Previous hash: ${prev_short}
New hash:      ${new_hash:0:12}
Updated:       ${timestamp}

Content hash changed — URL-sourced skill re-imported."

	printf '%s\n\n%s\n' "$subject" "$body"
	return 0
}

# Generate the full PR body for a URL-sourced skill update (t1415.2).
# Arguments:
#   $1 - skill name
#   $2 - upstream URL
#   $3 - previous hash (may be empty)
#   $4 - new hash
#   $5 - diff summary (multi-line string, may be empty)
# Outputs: PR body markdown
# Returns: 0 always
generate_url_skill_pr_body() {
	local skill_name="$1"
	local upstream_url="$2"
	local prev_hash="$3"
	local new_hash="$4"
	local diff_summary="$5"

	local prev_display="${prev_hash:0:12}"
	[[ -z "$prev_display" ]] && prev_display="_(none -- first import)_"

	cat <<PREOF
## Skill Update: \`${skill_name}\` (URL source)

Automated skill update — upstream URL content changed (SHA-256 hash mismatch).

| Field | Value |
|-------|-------|
| Skill | \`${skill_name}\` |
| Source | ${upstream_url} |
| Previous hash | \`${prev_display}\` |
| New hash | \`${new_hash:0:12}\` |
| Detection | Content hash (SHA-256) |

### Upstream changelog

_Not available for URL-sourced skills (no git history). Review the diff below for changes._

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
*Generated by \`skill-update-helper.sh pr\` (t1415.2)*
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

# Create or reuse a worktree for a given branch name.
# Uses worktree-helper.sh if available, falls back to direct git worktree add.
# Arguments:
#   $1 - branch name
#   $2 - repo root path
#   $3 - label for error messages (e.g. skill name or "batch")
# Outputs: worktree path on stdout
# Returns: 0 on success, 1 on failure
_create_worktree_for_branch() {
	local branch_name="$1"
	local repo_root="$2"
	local label="$3"

	local worktree_path=""

	if [[ -x "$WORKTREE_HELPER" ]]; then
		local wt_output
		wt_output=$("$WORKTREE_HELPER" add "$branch_name" 2>&1) || {
			if echo "$wt_output" | grep -q "already exists"; then
				worktree_path=$(echo "$wt_output" | grep -oE '/[^ ]+' | head -1)
				log_info "Using existing worktree: $worktree_path"
			else
				log_error "Failed to create worktree for $label: $wt_output"
				return 1
			fi
		}
		if [[ -z "${worktree_path:-}" ]]; then
			worktree_path=$(echo "$wt_output" | grep "^Path:" | sed 's/^Path: *//' | head -1)
			worktree_path=$(echo "$worktree_path" | sed 's/\x1b\[[0-9;]*m//g')
		fi
	fi

	if [[ -z "${worktree_path:-}" ]]; then
		local parent_dir repo_name slug
		parent_dir=$(dirname "$repo_root")
		repo_name=$(basename "$repo_root")
		slug=$(echo "$branch_name" | tr '/' '-' | tr '[:upper:]' '[:lower:]')
		worktree_path="${parent_dir}/${repo_name}-${slug}"

		if [[ -d "$worktree_path" ]]; then
			log_info "Using existing worktree: $worktree_path"
		else
			log_info "Creating worktree at: $worktree_path"
			local wt_add_output
			if git show-ref --verify --quiet "refs/heads/$branch_name" 2>/dev/null; then
				wt_add_output=$(git worktree add "$worktree_path" "$branch_name" 2>&1) || {
					log_error "Failed to create worktree for $label: ${wt_add_output}"
					return 1
				}
			else
				wt_add_output=$(git worktree add -b "$branch_name" "$worktree_path" 2>&1) || {
					log_error "Failed to create worktree for $label: ${wt_add_output}"
					return 1
				}
			fi
			register_worktree "$worktree_path" "$branch_name"
		fi
	fi

	if [[ ! -d "$worktree_path" ]]; then
		log_error "Worktree path does not exist: $worktree_path"
		return 1
	fi

	echo "$worktree_path"
	return 0
}

# Push a branch and create a PR via gh CLI.
# Arguments:
#   $1 - worktree path
#   $2 - branch name
#   $3 - default branch (base)
#   $4 - PR title
#   $5 - PR body
#   $6 - label for error messages (e.g. skill name or "batch")
# Returns: 0 on success, 1 on failure
_push_and_create_pr() {
	local worktree_path="$1"
	local branch_name="$2"
	local default_branch="$3"
	local pr_title="$4"
	local pr_body="$5"
	local label="$6"

	local push_output
	push_output=$(git -C "$worktree_path" push -u origin "$branch_name" 2>&1) || {
		log_error "Failed to push branch for $label: ${push_output}"
		return 1
	}
	log_success "Pushed branch: $branch_name"

	if ! command -v gh &>/dev/null; then
		log_warning "gh CLI not available — branch pushed but PR not created"
		log_info "Create PR manually: gh pr create --head $branch_name"
		return 0
	fi

	if ! gh auth status &>/dev/null; then
		log_warning "gh auth unavailable — branch pushed but PR not created for $label"
		log_info "Authenticate with: gh auth login"
		log_info "Create PR manually: gh pr create --head $branch_name"
		return 1
	fi

	# Append signature footer
	local sig_footer=""
	sig_footer=$("${HOME}/.aidevops/agents/scripts/gh-signature-helper.sh" footer --body "$pr_body" 2>/dev/null || true)
	pr_body="${pr_body}${sig_footer}"

	# Detect session origin for PR label
	local origin_label="origin:worker"
	if type detect_session_origin &>/dev/null; then
		origin_label="origin:$(detect_session_origin)"
	fi

	local pr_create_output
	pr_create_output=$(gh pr create \
		--head "$branch_name" \
		--base "$default_branch" \
		--title "$pr_title" \
		--body "$pr_body" \
		--label "$origin_label" \
		--repo "$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || echo '')" \
		2>&1) || {
		log_error "Failed to create PR for $label: ${pr_create_output}"
		log_info "Branch is pushed — create PR manually: gh pr create --head $branch_name"
		return 1
	}

	log_success "PR created for $label: $pr_create_output"
	return 0
}

# Build commit message and PR artifacts for a single skill update, then commit.
# Arguments:
#   $1 - worktree path
#   $2 - skill name
#   $3 - upstream URL
#   $4 - current commit/hash
#   $5 - latest commit/hash
#   $6 - source type: "github" or "url"
#   $7 - default branch
# Outputs: sets caller-local pr_title and pr_body (via echo to stdout — caller captures)
# Returns: 0 on success, 1 on failure
# Note: caller must capture pr_title and pr_body separately; this function commits and
#       echoes "PR_TITLE:<title>" then "PR_BODY_START" ... "PR_BODY_END" to stdout.
#       Simpler: function sets globals _PR_TITLE and _PR_BODY for the caller.
_PR_TITLE=""
_PR_BODY=""
_commit_skill_update() {
	local worktree_path="$1"
	local skill_name="$2"
	local upstream_url="$3"
	local current_commit="$4"
	local latest_commit="$5"
	local source_type="$6"
	local default_branch="$7"

	git -C "$worktree_path" add -A
	local diff_summary
	diff_summary=$(get_skill_diff_summary "$worktree_path" "$default_branch")

	local commit_msg
	if [[ "$source_type" == "url" ]]; then
		commit_msg=$(generate_url_skill_commit_msg \
			"$skill_name" "$upstream_url" "$current_commit" "$latest_commit")
		_PR_TITLE="chore(skill/${skill_name}): update from upstream URL (${latest_commit:0:12})"
		_PR_BODY=$(generate_url_skill_pr_body \
			"$skill_name" "$upstream_url" "$current_commit" "$latest_commit" "$diff_summary")
		update_upstream_hash "$skill_name" "$latest_commit"
	else
		local owner_repo_for_log changelog=""
		owner_repo_for_log=$(parse_github_url "$upstream_url")
		owner_repo_for_log=$(echo "$owner_repo_for_log" | cut -d'/' -f1-2)
		if [[ -n "$owner_repo_for_log" && "$owner_repo_for_log" != "/" ]]; then
			log_info "Fetching upstream changelog for $skill_name..."
			changelog=$(get_upstream_changelog "$owner_repo_for_log" "$current_commit" "$latest_commit" 2>/dev/null || true)
		fi
		commit_msg=$(generate_skill_commit_msg \
			"$skill_name" "$upstream_url" "$current_commit" "$latest_commit" "$changelog")
		_PR_TITLE="chore(skill/${skill_name}): update from upstream (${latest_commit:0:7})"
		_PR_BODY=$(generate_skill_pr_body \
			"$skill_name" "$upstream_url" "$current_commit" "$latest_commit" \
			"$changelog" "$diff_summary")
	fi

	local commit_output
	commit_output=$(git -C "$worktree_path" commit -m "$commit_msg" --no-verify 2>&1) || {
		log_error "Failed to commit changes for $skill_name: ${commit_output}"
		return 1
	}
	log_success "Committed skill update for $skill_name"
	return 0
}

# Process a single skill update: worktree -> re-import -> commit -> PR
# Arguments:
#   $1 - skill name
#   $2 - upstream URL
#   $3 - current commit/hash (for PR body context)
#   $4 - latest commit/hash
#   $5 - source type: "github" (default) or "url" (t1415.2)
# Returns: 0 on success, 1 on failure
cmd_pr_single() {
	local skill_name="$1"
	local upstream_url="$2"
	local current_commit="$3"
	local latest_commit="$4"
	local source_type="${5:-github}"

	local repo_root
	repo_root=$(get_repo_root)
	if [[ -z "$repo_root" ]]; then
		log_error "Not in a git repository"
		return 1
	fi

	local default_branch
	default_branch=$(get_default_branch)

	local branch_name="chore/skill-update-${skill_name}"

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

	local worktree_path
	worktree_path=$(_create_worktree_for_branch "$branch_name" "$repo_root" "$skill_name") || return 1

	# Re-import the skill in the worktree context
	log_info "Re-importing $skill_name in worktree..."
	local add_skill_in_wt="${worktree_path}/.agents/scripts/add-skill-helper.sh"
	if [[ ! -x "$add_skill_in_wt" ]]; then
		add_skill_in_wt="$ADD_SKILL_HELPER"
	fi

	if ! (cd "$worktree_path" && "$add_skill_in_wt" add "$upstream_url" --force --skip-security 2>&1); then
		log_error "Failed to re-import $skill_name"
		_cleanup_worktree "$worktree_path" "$branch_name"
		return 1
	fi

	# Check if there are actual changes
	if git -C "$worktree_path" diff --quiet && git -C "$worktree_path" diff --cached --quiet; then
		local untracked
		untracked=$(git -C "$worktree_path" ls-files --others --exclude-standard 2>/dev/null || echo "")
		if [[ -z "$untracked" ]]; then
			log_info "No changes detected for $skill_name after re-import — skipping"
			_cleanup_worktree "$worktree_path" "$branch_name"
			return 0
		fi
	fi

	if ! _commit_skill_update \
		"$worktree_path" "$skill_name" "$upstream_url" \
		"$current_commit" "$latest_commit" "$source_type" "$default_branch"; then
		_cleanup_worktree "$worktree_path" "$branch_name"
		return 1
	fi

	_push_and_create_pr \
		"$worktree_path" "$branch_name" "$default_branch" \
		"$_PR_TITLE" "$_PR_BODY" "$skill_name"
	return $?
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

# Scan skill-sources.json and collect skills that need updates into parallel arrays.
# Populates the caller's skills_to_update, skill_urls, skill_current_commits,
# skill_latest_commits arrays (caller must declare them before calling).
# Arguments:
#   $1 - target skill name filter (empty = all skills)
# Returns: 0 always (individual failures are logged and skipped)
_collect_skills_needing_update() {
	local target_skill="${1:-}"

	while IFS= read -r skill_json; do
		local name upstream_url current_commit
		name=$(echo "$skill_json" | jq -r '.name')
		upstream_url=$(echo "$skill_json" | jq -r '.upstream_url')
		current_commit=$(echo "$skill_json" | jq -r '.upstream_commit // empty')

		if [[ -n "$target_skill" && "$name" != "$target_skill" ]]; then
			continue
		fi

		if is_url_skill "$skill_json"; then
			local stored_hash stored_etag stored_last_modified latest_hash
			stored_hash=$(echo "$skill_json" | jq -r '.upstream_hash // empty')
			stored_etag=$(echo "$skill_json" | jq -r '.upstream_etag // empty')
			stored_last_modified=$(echo "$skill_json" | jq -r '.upstream_last_modified // empty')

			if ! latest_hash=$(fetch_url_conditional "$upstream_url" "$stored_etag" "$stored_last_modified"); then
				log_warning "Could not fetch URL for $name: $upstream_url — skipping"
				continue
			fi
			update_cache_headers "$name" "$FETCH_RESP_ETAG" "$FETCH_RESP_LAST_MODIFIED"
			update_last_checked "$name"

			if [[ "$latest_hash" == "not_modified" ]]; then
				[[ "$QUIET" != true ]] && echo -e "${GREEN}Up to date${NC}: $name (304 Not Modified)"
				continue
			fi
			if [[ -n "$stored_hash" && "$latest_hash" == "$stored_hash" ]]; then
				[[ "$QUIET" != true ]] && echo -e "${GREEN}Up to date${NC}: $name"
				continue
			fi

			log_info "Update available: $name (hash ${stored_hash:0:12} → ${latest_hash:0:12})"
			skills_to_update+=("$name")
			skill_urls+=("$upstream_url")
			skill_current_commits+=("$stored_hash")
			skill_latest_commits+=("$latest_hash")
			continue
		fi

		if [[ "$upstream_url" != *"github.com"* ]]; then
			[[ "$QUIET" != true ]] && log_info "Skipping $name (non-GitHub source: ${upstream_url})"
			continue
		fi

		local owner_repo latest_commit
		owner_repo=$(parse_github_url "$upstream_url")
		owner_repo=$(echo "$owner_repo" | cut -d'/' -f1-2)

		if [[ -z "$owner_repo" || "$owner_repo" == "/" ]]; then
			log_warning "Could not parse URL for $name: $upstream_url — skipping"
			continue
		fi
		if ! latest_commit=$(get_latest_commit "$owner_repo"); then
			log_warning "Could not fetch latest commit for $name ($owner_repo) — skipping"
			continue
		fi
		update_last_checked "$name"

		if [[ -n "$current_commit" && "$latest_commit" == "$current_commit" ]]; then
			[[ "$QUIET" != true ]] && echo -e "${GREEN}Up to date${NC}: $name"
			continue
		fi

		log_info "Update available: $name (${current_commit:0:7} → ${latest_commit:0:7})"
		skills_to_update+=("$name")
		skill_urls+=("$upstream_url")
		skill_current_commits+=("$current_commit")
		skill_latest_commits+=("$latest_commit")

	done < <(jq -c '.skills[]' "$SKILL_SOURCES")
	return 0
}

# Re-import each skill in a worktree, populating imported_skills and failed_skills arrays.
# Arguments:
#   $1 - worktree path
# Reads: skills_to_update, skill_urls (parallel arrays from caller)
# Populates: imported_skills, failed_skills (caller must declare them)
# Returns: 0 always
_reimport_skills_in_worktree() {
	local worktree_path="$1"

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
	return 0
}

# Update upstream_hash for URL-sourced skills that were successfully re-imported.
# Arguments:
#   $1 - newline-separated list of successfully imported skill names
# Reads: skills_to_update, skill_latest_commits (parallel arrays from caller)
# Returns: 0 always
_update_url_skill_hashes() {
	local imported_skills_list="$1"

	for i in "${!skills_to_update[@]}"; do
		local sname="${skills_to_update[$i]}"
		local sformat
		sformat=$(jq -r --arg name "$sname" '.skills[] | select(.name == $name) | .format_detected // empty' "$SKILL_SOURCES")
		if [[ "$sformat" != "url" ]]; then
			continue
		fi
		if echo "$imported_skills_list" | grep -qxF "$sname"; then
			update_upstream_hash "$sname" "${skill_latest_commits[$i]}"
			log_info "Updated upstream_hash for URL skill: $sname"
		fi
	done
	return 0
}

# Build the batch commit message and commit staged changes.
# Arguments:
#   $1 - worktree path
#   $2 - branch name (for cleanup on failure)
#   $3 - timestamp (YYYYMMDD)
#   $4 - newline-separated list of successfully imported skill names
# Reads: skills_to_update, skill_current_commits, skill_latest_commits, imported_skills
# Returns: 0 on success, 1 on failure
_commit_batch_changes() {
	local worktree_path="$1"
	local branch_name="$2"
	local timestamp="$3"
	local imported_skills_list="$4"

	git -C "$worktree_path" add -A

	local commit_msg="chore: batch update ${#imported_skills[@]} skill(s) from upstream (t1082.3)"$'\n'$'\n'
	for i in "${!skills_to_update[@]}"; do
		local sname="${skills_to_update[$i]}"
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
	return 0
}

# Build the batch PR body and create the PR via gh CLI.
# Arguments:
#   $1 - worktree path
#   $2 - branch name
#   $3 - default branch
#   $4 - newline-separated list of successfully imported skill names
# Reads: skills_to_update, skill_current_commits, skill_latest_commits, skill_urls,
#        imported_skills, failed_skills
# Returns: 0 on success, 1 on failure
_create_batch_pr() {
	local worktree_path="$1"
	local branch_name="$2"
	local default_branch="$3"
	local imported_skills_list="$4"

	local push_output
	push_output=$(git -C "$worktree_path" push -u origin "$branch_name" 2>&1) || {
		log_error "Failed to push batch branch: ${push_output}"
		return 1
	}
	log_success "Pushed batch branch: $branch_name"

	if ! command -v gh &>/dev/null; then
		log_warning "gh CLI not available — branch pushed but PR not created"
		log_info "Create PR manually: gh pr create --head $branch_name"
		return 0
	fi
	if ! gh auth status &>/dev/null; then
		log_warning "gh auth unavailable — branch pushed but batch PR not created"
		log_info "Authenticate with: gh auth login"
		log_info "Create PR manually: gh pr create --head $branch_name"
		return 1
	fi

	local skill_table="| Skill | Previous | Latest | Source |"$'\n'
	skill_table+="|-------|----------|--------|--------|"$'\n'
	for i in "${!skills_to_update[@]}"; do
		local sname="${skills_to_update[$i]}"
		if echo "$imported_skills_list" | grep -qxF "$sname"; then
			skill_table+="| \`${sname}\` | \`${skill_current_commits[$i]:0:12}\` | \`${skill_latest_commits[$i]:0:12}\` | ${skill_urls[$i]} |"$'\n'
		fi
	done

	local failed_note=""
	if [[ "${#failed_skills[@]}" -gt 0 ]]; then
		failed_note=$'\n'"**Note**: The following skills failed to re-import and are NOT included in this PR: ${failed_skills[*]}"$'\n'
	fi

	local pr_title="chore: batch update ${#imported_skills[@]} skill(s) from upstream"
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

	# Append signature footer
	local batch_sig=""
	batch_sig=$("${HOME}/.aidevops/agents/scripts/gh-signature-helper.sh" footer --body "$pr_body" 2>/dev/null || true)
	pr_body="${pr_body}${batch_sig}"

	local repo_name_with_owner
	repo_name_with_owner=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)
	# Detect session origin for PR label
	local batch_origin_label="origin:worker"
	if type detect_session_origin &>/dev/null; then
		batch_origin_label="origin:$(detect_session_origin)"
	fi

	local pr_create_args=("--head" "$branch_name" "--base" "$default_branch" "--title" "$pr_title" "--body" "$pr_body" "--label" "$batch_origin_label")
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
	return 0
}

# Create one PR containing updates for all skills that have upstream changes.
# Arguments:
#   $1 - target skill name (optional; empty = all skills)
# Returns: 0 on success, 1 on failure
# Re-import skills into a worktree, update URL hashes, and verify changes exist.
# Arguments:
#   $1 - worktree path
#   $2 - branch name (for cleanup on no-change exit)
# Reads/populates: imported_skills, failed_skills (caller must declare them)
# Reads: skills_to_update, skill_urls, skill_latest_commits
# Returns: 0 if changes exist and ready to commit, 1 on failure or no changes
_batch_reimport_and_verify() {
	local worktree_path="$1"
	local branch_name="$2"

	_reimport_skills_in_worktree "$worktree_path"

	# Build newline-separated list for grep-based membership checks (bash 3.2 compatible)
	local imported_skills_list=""
	for imp in "${imported_skills[@]}"; do
		imported_skills_list="${imported_skills_list:+$imported_skills_list
}$imp"
	done

	_update_url_skill_hashes "$imported_skills_list"

	if [[ "${#imported_skills[@]}" -eq 0 ]]; then
		log_error "No skills were successfully imported — aborting batch PR"
		_cleanup_worktree "$worktree_path" "$branch_name"
		return 1
	fi

	if git -C "$worktree_path" diff --quiet && git -C "$worktree_path" diff --cached --quiet; then
		local untracked
		untracked=$(git -C "$worktree_path" ls-files --others --exclude-standard 2>/dev/null || echo "")
		if [[ -z "$untracked" ]]; then
			log_info "No changes detected after re-importing all skills — skipping"
			_cleanup_worktree "$worktree_path" "$branch_name"
			return 1
		fi
	fi

	# Echo the list so the caller can capture it without a global
	echo "$imported_skills_list"
	return 0
}

cmd_pr_batch() {
	local target_skill="${1:-}"

	require_jq

	local skill_count
	skill_count=$(check_skill_sources)

	log_info "Checking $skill_count imported skill(s) for upstream updates (batch mode)..."
	echo ""

	if [[ "$DRY_RUN" != true ]] && ! command -v gh &>/dev/null; then
		log_error "gh CLI is required for PR creation"
		log_info "Install with: brew install gh (macOS) or see https://cli.github.com/"
		return 1
	fi

	local repo_root default_branch
	repo_root=$(get_repo_root)
	if [[ -z "$repo_root" ]]; then
		log_error "Not in a git repository"
		return 1
	fi
	default_branch=$(get_default_branch)

	local skills_to_update=() skill_urls=() skill_current_commits=() skill_latest_commits=()
	_collect_skills_needing_update "$target_skill"

	local update_count="${#skills_to_update[@]}"
	if [[ "$update_count" -eq 0 ]]; then
		log_info "No skills require updates — no PR needed"
		return 0
	fi

	log_info "Found $update_count skill(s) with updates"
	echo ""

	local timestamp branch_name
	timestamp=$(date -u +"%Y%m%d")
	branch_name="chore/skill-update-batch-${timestamp}"

	if [[ "$DRY_RUN" == true ]]; then
		log_info "DRY RUN: Would create single batch PR for $update_count skill(s)"
		echo "  Branch: $branch_name"
		for i in "${!skills_to_update[@]}"; do
			echo "  - ${skills_to_update[$i]}: ${skill_current_commits[$i]:0:7} → ${skill_latest_commits[$i]:0:7}"
		done
		echo ""
		return 0
	fi

	if command -v gh &>/dev/null; then
		local existing_pr
		existing_pr=$(gh pr list --head "$branch_name" --state open --json number --jq '.[0].number' 2>/dev/null || echo "")
		if [[ -n "$existing_pr" ]]; then
			log_warning "PR #${existing_pr} already open for batch branch $branch_name — skipping"
			return 0
		fi
	fi

	local worktree_path
	worktree_path=$(_create_worktree_for_branch "$branch_name" "$repo_root" "batch") || return 1

	local imported_skills=() failed_skills=()
	local imported_skills_list
	imported_skills_list=$(_batch_reimport_and_verify "$worktree_path" "$branch_name") || return 1

	_commit_batch_changes "$worktree_path" "$branch_name" "$timestamp" "$imported_skills_list" || return 1
	_create_batch_pr "$worktree_path" "$branch_name" "$default_branch" "$imported_skills_list" || return 1

	if [[ "${#failed_skills[@]}" -gt 0 ]]; then
		return 1
	fi
	return 0
}

# Check a URL-sourced skill and create a PR if an update is available.
# Increments caller's prs_created, prs_skipped, or prs_failed counters.
# Arguments:
#   $1 - skill JSON object (from jq -c)
#   $2 - skill name
#   $3 - upstream URL
# Returns: 0 always (counters reflect outcome)
_pr_check_url_skill() {
	local skill_json="$1"
	local name="$2"
	local upstream_url="$3"

	local stored_hash stored_etag stored_last_modified latest_hash
	stored_hash=$(echo "$skill_json" | jq -r '.upstream_hash // empty')
	stored_etag=$(echo "$skill_json" | jq -r '.upstream_etag // empty')
	stored_last_modified=$(echo "$skill_json" | jq -r '.upstream_last_modified // empty')

	if ! latest_hash=$(fetch_url_conditional "$upstream_url" "$stored_etag" "$stored_last_modified"); then
		log_warning "Could not fetch URL for $name: $upstream_url — skipping"
		((++prs_skipped))
		return 0
	fi

	update_cache_headers "$name" "$FETCH_RESP_ETAG" "$FETCH_RESP_LAST_MODIFIED"
	update_last_checked "$name"

	if [[ "$latest_hash" == "not_modified" ]]; then
		[[ "$QUIET" != true ]] && echo -e "${GREEN}Up to date${NC}: $name (304 Not Modified)"
		return 0
	fi
	if [[ -n "$stored_hash" && "$latest_hash" == "$stored_hash" ]]; then
		[[ "$QUIET" != true ]] && echo -e "${GREEN}Up to date${NC}: $name"
		return 0
	fi

	if cmd_pr_single "$name" "$upstream_url" "$stored_hash" "$latest_hash" "url"; then
		((++prs_created))
	else
		((++prs_failed))
	fi
	return 0
}

# Check a GitHub-sourced skill and create a PR if an update is available.
# Increments caller's prs_created, prs_skipped, or prs_failed counters.
# Arguments:
#   $1 - skill name
#   $2 - upstream URL
#   $3 - current commit SHA (may be empty)
# Returns: 0 always (counters reflect outcome)
_pr_check_github_skill() {
	local name="$1"
	local upstream_url="$2"
	local current_commit="$3"

	if [[ "$upstream_url" != *"github.com"* ]]; then
		[[ "$QUIET" != true ]] && log_info "Skipping $name (non-GitHub source: ${upstream_url})"
		((++prs_skipped))
		return 0
	fi

	local owner_repo latest_commit
	owner_repo=$(parse_github_url "$upstream_url")
	owner_repo=$(echo "$owner_repo" | cut -d'/' -f1-2)

	if [[ -z "$owner_repo" || "$owner_repo" == "/" ]]; then
		log_warning "Could not parse URL for $name: $upstream_url — skipping"
		((++prs_skipped))
		return 0
	fi
	if ! latest_commit=$(get_latest_commit "$owner_repo"); then
		log_warning "Could not fetch latest commit for $name ($owner_repo) — skipping"
		((++prs_skipped))
		return 0
	fi

	update_last_checked "$name"

	if [[ -n "$current_commit" && "$latest_commit" == "$current_commit" ]]; then
		[[ "$QUIET" != true ]] && echo -e "${GREEN}Up to date${NC}: $name"
		return 0
	fi

	if cmd_pr_single "$name" "$upstream_url" "$current_commit" "$latest_commit" "github"; then
		((++prs_created))
	else
		((++prs_failed))
	fi
	return 0
}

# Orchestrator: check all skills and create PRs for those with updates.
# Dispatches to cmd_pr_batch (single-pr mode) or iterates cmd_pr_single
# (one-per-skill mode, default) based on BATCH_MODE.
cmd_pr() {
	local target_skill="${1:-}"

	if [[ "$BATCH_MODE" == "single-pr" ]]; then
		log_info "Batch mode: single-pr — all updated skills will be combined into one PR"
		cmd_pr_batch "$target_skill"
		return $?
	fi

	require_jq

	local skill_count
	skill_count=$(check_skill_sources)

	log_info "Checking $skill_count imported skill(s) for upstream updates (one PR per skill)..."
	echo ""

	if [[ "$DRY_RUN" != true ]] && ! command -v gh &>/dev/null; then
		log_error "gh CLI is required for PR creation"
		log_info "Install with: brew install gh (macOS) or see https://cli.github.com/"
		return 1
	fi

	local current_branch default_branch
	current_branch=$(git branch --show-current 2>/dev/null || echo "")
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

		if [[ -n "$target_skill" && "$name" != "$target_skill" ]]; then
			continue
		fi

		if is_url_skill "$skill_json"; then
			_pr_check_url_skill "$skill_json" "$name" "$upstream_url"
			continue
		fi

		_pr_check_github_skill "$name" "$upstream_url" "$current_commit"

	done < <(jq -c '.skills[]' "$SKILL_SOURCES")

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
