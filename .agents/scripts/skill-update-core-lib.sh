#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Skill Update Core Library — Utilities, Check, Update, Status Commands
# =============================================================================
# Core utilities and sub-commands extracted from skill-update-helper.sh.
#
# Covers:
#   - Help text display
#   - Prerequisites (jq, skill-sources.json)
#   - URL / GitHub API utilities
#   - Conditional HTTP fetch with ETag/Last-Modified caching
#   - cmd_check, cmd_update, cmd_status
#
# Usage: source "${SCRIPT_DIR}/skill-update-core-lib.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, etc.)
#   - Global vars from skill-update-helper.sh orchestrator (SKILL_SOURCES,
#     ADD_SKILL_HELPER, NON_INTERACTIVE, QUIET, AUTO_UPDATE, JSON_OUTPUT,
#     DRY_RUN, SKILL_LOG_FILE)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_SKILL_UPDATE_CORE_LIB_LOADED:-}" ]] && return 0
_SKILL_UPDATE_CORE_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback (may already be set by orchestrator)
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	# Pure-bash dirname replacement — avoids external binary dependency
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# Help
# =============================================================================

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

# =============================================================================
# Prerequisites
# =============================================================================

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

# =============================================================================
# URL / GitHub API Utilities
# =============================================================================

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
# Check Sub-Command Helpers
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

# =============================================================================
# Commands: check, update, status
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
