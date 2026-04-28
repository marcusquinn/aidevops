#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Add Skill Helper — Command Implementations
# =============================================================================
# Command-level entry points for skill import: cmd_add (GitHub), cmd_add_url,
# cmd_add_clawdhub, cmd_list, cmd_check_updates, cmd_remove, and their
# private sub-routines.
#
# Usage: source "${SCRIPT_DIR}/add-skill-helper-commands.sh"
#
# Dependencies:
#   - shared-constants.sh (log_info, log_error, log_success, log_warning, etc.)
#   - add-skill-helper-core.sh (parse_github_url, detect_format, extract_skill_name,
#     extract_skill_description, to_kebab_case, determine_target_path, convert_skill_md,
#     register_skill, ensure_skill_sources, show_help)
#   - add-skill-helper-import.sh (scan_skill_security, _apply_conflict_resolution,
#     _finalize_import, _fetch_url_content, _resolve_skill_name,
#     _convert_and_install_files)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_ADD_SKILL_COMMANDS_LIB_LOADED:-}" ]] && return 0
_ADD_SKILL_COMMANDS_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# Commands
# =============================================================================

# Try to install via openskills CLI. Returns 0 if installed, 1 if not available/failed.
# Args: owner repo subpath custom_name
_try_openskills_install() {
	local owner="$1"
	local repo="$2"
	local subpath="$3"
	local custom_name="$4"

	if ! command -v openskills &>/dev/null; then
		return 1
	fi

	log_info "Using openskills to fetch skill..."
	if openskills install "$owner/$repo${subpath:+/$subpath}" --yes --universal 2>/dev/null; then
		log_success "Skill installed via openskills"
		local skill_name="${custom_name:-$(basename "${subpath:-$repo}")}"
		skill_name=$(to_kebab_case "$skill_name")
		register_skill "$skill_name" "https://github.com/$owner/$repo" ".agents/skills/${skill_name}-skill.md" "skill-md" "" "openskills" "Installed via openskills CLI"
		return 0
	fi

	log_warning "openskills failed, falling back to direct fetch"
	return 1
}

# Parse cmd_add options. Sets caller variables: custom_name, force, dry_run, skip_security
_parse_add_options() {
	while [[ $# -gt 0 ]]; do
		local opt="$1"
		case "$opt" in
		--name)
			local name_val="$2"
			_add_custom_name="$name_val"
			shift 2
			;;
		--force)
			_add_force=true
			shift
			;;
		--skip-security)
			_add_skip_security=true
			shift
			;;
		--dry-run)
			_add_dry_run=true
			shift
			;;
		*)
			log_error "Unknown option: $opt"
			return 1
			;;
		esac
	done
	return 0
}

# Detect source type and route to appropriate handler.
# Returns: 0 if delegated (caller should return), 1 if GitHub (caller continues)
_detect_and_route_source() {
	local url="$1"
	local custom_name="$2"
	local force="$3"
	local dry_run="$4"
	local skip_security="$5"

	# Detect ClawdHub source (clawdhub:slug or clawdhub.com URL)
	local clawdhub_slug=""

	if [[ "$url" == clawdhub:* ]]; then
		clawdhub_slug="${url#clawdhub:}"
	elif [[ "$url" == *clawdhub.com* ]]; then
		clawdhub_slug="${url#*clawdhub.com/}"
		clawdhub_slug="${clawdhub_slug#/}"
		clawdhub_slug="${clawdhub_slug%/}"
		if [[ "$clawdhub_slug" == */* ]]; then
			clawdhub_slug="${clawdhub_slug##*/}"
		fi
	fi

	if [[ -n "$clawdhub_slug" ]]; then
		cmd_add_clawdhub "$clawdhub_slug" "$custom_name" "$force" "$dry_run" "$skip_security"
		_route_exit_code=$?
		return 0
	fi

	# Detect raw URL source (not GitHub, not ClawdHub)
	if [[ "$url" =~ ^https?:// && "$url" != *github.com* && "$url" != *clawdhub.com* ]]; then
		cmd_add_url "$url" "$custom_name" "$force" "$dry_run" "$skip_security"
		_route_exit_code=$?
		return 0
	fi

	# Not delegated — caller handles as GitHub
	return 1
}

# Clone a GitHub repo and detect skill format/metadata.
# Sets in caller scope: source_dir, skill_source_dir, format, skill_subdir
# Args: owner repo subpath
_clone_and_prepare_github() {
	local owner="$1"
	local repo="$2"
	local subpath="$3"

	# Clone repository
	log_info "Cloning repository..."
	local clone_url="https://github.com/$owner/$repo.git"

	if ! git clone --depth 1 "$clone_url" "$TEMP_DIR/repo" 2>/dev/null; then
		log_error "Failed to clone repository: $clone_url"
		return 1
	fi

	# Navigate to subpath if specified
	source_dir="$TEMP_DIR/repo"
	if [[ -n "$subpath" ]]; then
		source_dir="$TEMP_DIR/repo/$subpath"
		if [[ ! -d "$source_dir" ]]; then
			log_error "Subpath not found: $subpath"
			return 1
		fi
	fi

	# Detect format (returns format|skill_subdir)
	local format_result
	format_result=$(detect_format "$source_dir")
	IFS='|' read -r format skill_subdir <<<"$format_result"
	log_info "Detected format: $format"

	# For nested skills, update source_dir to point to the skill directory
	skill_source_dir="$source_dir"
	if [[ "$format" == "skill-md-nested" && -n "$skill_subdir" ]]; then
		skill_source_dir="$source_dir/$skill_subdir"
		log_info "Found nested skill at: $skill_subdir"
	fi

	return 0
}

# Resolve skill name, description, and target path for a GitHub import.
# Sets in caller scope: skill_name, description, target_path
# Args: custom_name format skill_source_dir subpath repo
_resolve_github_skill_metadata() {
	local custom_name="$1"
	local format="$2"
	local skill_source_dir="$3"
	local subpath="$4"
	local repo="$5"

	# Determine skill name
	skill_name=""
	if [[ -n "$custom_name" ]]; then
		skill_name=$(to_kebab_case "$custom_name")
	elif [[ "$format" == "skill-md" || "$format" == "skill-md-nested" ]]; then
		skill_name=$(extract_skill_name "$skill_source_dir/SKILL.md")
		skill_name=$(to_kebab_case "${skill_name:-$(basename "${subpath:-$repo}")}")
	else
		skill_name=$(to_kebab_case "$(basename "${subpath:-$repo}")")
	fi

	log_info "Skill name: $skill_name"

	# Get description
	description=""
	if [[ "$format" == "skill-md" || "$format" == "skill-md-nested" ]]; then
		description=$(extract_skill_description "$skill_source_dir/SKILL.md")
	fi

	# Determine target path
	target_path=$(determine_target_path "$skill_name" "$description" "$skill_source_dir")
	log_info "Target path: .agents/$target_path"

	return 0
}

# Execute the GitHub-specific import path for cmd_add.
# Caller must have already parsed options and routed away non-GitHub sources.
# Args: $1=url $2=owner $3=repo $4=subpath $5=custom_name $6=force $7=dry_run $8=skip_security
_cmd_add_github() {
	local url="$1"
	local owner="$2"
	local repo="$3"
	local subpath="$4"
	local custom_name="$5"
	local force="$6"
	local dry_run="$7"
	local skip_security="$8"

	# Create temp directory
	rm -rf "$TEMP_DIR"
	mkdir -p "$TEMP_DIR"

	# Try openskills first (returns 0 if installed successfully)
	if _try_openskills_install "$owner" "$repo" "$subpath" "$custom_name"; then
		return 0
	fi

	# Clone and detect format (sets source_dir, skill_source_dir, format, skill_subdir)
	local source_dir="" skill_source_dir="" format="" skill_subdir=""
	if ! _clone_and_prepare_github "$owner" "$repo" "$subpath"; then
		return 1
	fi

	# Resolve metadata (sets skill_name, description, target_path)
	local skill_name="" description="" target_path=""
	_resolve_github_skill_metadata "$custom_name" "$format" "$skill_source_dir" "$subpath" "$repo"

	# Handle conflicts (may update skill_name/target_path in caller scope)
	if ! _apply_conflict_resolution "$target_path" "$force" "$description" "$source_dir"; then
		rm -rf "$TEMP_DIR"
		return 1
	fi

	if [[ "$dry_run" == true ]]; then
		log_info "DRY RUN - Would create:"
		echo "  .agents/${target_path}.md"
		if [[ -d "$skill_source_dir/scripts" || -d "$skill_source_dir/references" ]]; then
			echo "  .agents/${target_path}/"
		fi
		return 0
	fi

	# Convert and install files
	local target_file=".agents/${target_path}.md"
	if ! _convert_and_install_files "$format" "$source_dir" "$skill_source_dir" "$target_file" "$skill_name" "$target_path"; then
		return 1
	fi

	# Get commit hash for tracking
	local commit_hash=""
	if [[ -d "$TEMP_DIR/repo/.git" ]]; then
		commit_hash=$(git -C "$TEMP_DIR/repo" rev-parse HEAD 2>/dev/null || echo "")
	fi

	# Finalize: security scan, register, cleanup
	if ! _finalize_import "$skill_source_dir" "$skill_name" "$skip_security" \
		"$target_file" "$target_path" \
		"https://github.com/$owner/$repo${subpath:+/$subpath}" \
		".agents/${target_path}.md" "$format" "$commit_hash" \
		"added" "" "" "" "" "$TEMP_DIR"; then
		return 1
	fi

	log_success "Skill '$skill_name' imported successfully"
	echo ""
	log_info "Run './setup.sh' to create symlinks for other AI assistants"
	return 0
}

cmd_add() {
	local url="$1"
	shift

	# Parse options (sets _add_* globals)
	_add_custom_name=""
	_add_force=false
	_add_skip_security=false
	_add_dry_run=false
	if ! _parse_add_options "$@"; then
		return 1
	fi
	local custom_name="$_add_custom_name"
	local force="$_add_force"
	local dry_run="$_add_dry_run"
	local skip_security="$_add_skip_security"

	log_info "Parsing source: $url"

	# Route to ClawdHub or URL handler if applicable
	_route_exit_code=0
	if _detect_and_route_source "$url" "$custom_name" "$force" "$dry_run" "$skip_security"; then
		return "$_route_exit_code"
	fi

	# Parse GitHub URL
	local parsed owner repo subpath
	parsed=$(parse_github_url "$url")
	IFS='|' read -r owner repo subpath <<<"$parsed"

	if [[ -z "$owner" || -z "$repo" ]]; then
		log_error "Could not parse source URL: $url"
		log_info "Expected: owner/repo, https://github.com/owner/repo, clawdhub:slug, or a raw URL"
		return 1
	fi

	log_info "Owner: $owner, Repo: $repo, Subpath: ${subpath:-<root>}"

	_cmd_add_github "$url" "$owner" "$repo" "$subpath" "$custom_name" "$force" "$dry_run" "$skip_security"
	return $?
}

# Convert fetched URL content to aidevops format.
# Args: fetch_file target_file skill_name description url
_convert_url_to_skill() {
	local fetch_file="$1"
	local target_file="$2"
	local skill_name="$3"
	local description="$4"
	local url="$5"

	# Create target directory
	local target_dir
	target_dir=".agents/$(dirname "${target_file#.agents/}")"
	mkdir -p "$target_dir"

	# Check if the fetched file has SKILL.md frontmatter
	local has_frontmatter=false
	if head -1 "$fetch_file" | grep -q "^---$"; then
		has_frontmatter=true
	fi

	if [[ "$has_frontmatter" == true ]]; then
		convert_skill_md "$fetch_file" "$target_file" "$skill_name"
	else
		local safe_description
		safe_description=$(printf '%s' "${description:-Imported from URL}" | sed 's/\\/\\\\/g; s/"/\\"/g')

		cat >"$target_file" <<EOF
---
description: "${safe_description}"
mode: subagent
imported_from: url
source_url: "${url}"
---
# ${skill_name}

EOF
		cat "$fetch_file" >>"$target_file"
	fi

	log_success "Created: $target_file"
	return 0
}

# Fetch SKILL.md from ClawdHub and convert to aidevops format.
# Args: slug fetch_dir target_file display_name skill_name summary version
_fetch_and_convert_clawdhub() {
	local slug="$1"
	local fetch_dir="$2"
	local target_file="$3"
	local display_name="$4"
	local skill_name="$5"
	local summary="$6"
	local version="$7"

	# Fetch SKILL.md content using clawdhub-helper.sh (Playwright-based)
	local helper_script
	helper_script="$(dirname "$0")/clawdhub-helper.sh"

	rm -rf "$fetch_dir"

	if [[ -x "$helper_script" ]]; then
		if ! "$helper_script" fetch "$slug" --output "$fetch_dir"; then
			log_error "Failed to fetch SKILL.md from ClawdHub"
			return 1
		fi
	else
		log_error "clawdhub-helper.sh not found at: $helper_script"
		return 1
	fi

	# Verify SKILL.md was fetched
	if [[ ! -f "$fetch_dir/SKILL.md" || ! -s "$fetch_dir/SKILL.md" ]]; then
		log_error "SKILL.md not found or empty after fetch"
		return 1
	fi

	# Create target directory and convert to aidevops format
	local target_dir
	target_dir=".agents/$(dirname "${target_file#.agents/}")"
	mkdir -p "$target_dir"

	local safe_summary
	safe_summary=$(printf '%s' "${summary:-Imported from ClawdHub}" | sed 's/\\/\\\\/g; s/"/\\"/g')

	cat >"$target_file" <<EOF
---
description: "${safe_summary}"
mode: subagent
imported_from: clawdhub
clawdhub_slug: "${slug}"
clawdhub_version: "${version}"
---
# ${display_name:-$skill_name}

EOF

	# Append the fetched SKILL.md content (skip any existing frontmatter)
	awk '
        BEGIN { in_frontmatter = 0; after_frontmatter = 0; has_frontmatter = 0 }
        NR == 1 && /^---$/ { in_frontmatter = 1; has_frontmatter = 1; next }
        in_frontmatter && /^---$/ { in_frontmatter = 0; after_frontmatter = 1; next }
        in_frontmatter { next }
        !has_frontmatter || after_frontmatter { print }
    ' "$fetch_dir/SKILL.md" >>"$target_file"

	log_success "Created: $target_file"
	return 0
}

# Import a skill from a raw URL (not GitHub, not ClawdHub)
# Fetches with curl, computes SHA-256 content hash, registers with format_detected: "url"
cmd_add_url() {
	local url="$1"
	local custom_name="$2"
	local force="$3"
	local dry_run="$4"
	local skip_security="${5:-false}"

	log_info "Importing from URL: $url"

	# Create temp directory for fetched content
	local fetch_dir="${TMPDIR:-/tmp}/aidevops-url-fetch"
	rm -rf "$fetch_dir"
	mkdir -p "$fetch_dir"

	# Fetch and validate URL content (sets fetch_file, resp_etag, resp_last_modified, content_hash)
	local fetch_file="" resp_etag="" resp_last_modified="" content_hash="" header_file=""
	if ! _fetch_url_content "$url" "$fetch_dir"; then
		return 1
	fi

	# Determine skill name
	local skill_name
	skill_name=$(_resolve_skill_name "$custom_name" "$fetch_file" "$(basename "${url%.md}")" "$url")
	log_info "Skill name: $skill_name"

	# Extract description from frontmatter if available
	local description=""
	description=$(extract_skill_description "$fetch_file")

	# Copy fetched file as SKILL.md for format detection compatibility
	cp "$fetch_file" "$fetch_dir/SKILL.md" 2>/dev/null || true

	# Determine target path
	local target_path
	target_path=$(determine_target_path "$skill_name" "$description" "$fetch_dir")
	log_info "Target path: .agents/$target_path"

	# Handle conflicts (may update skill_name/target_path in caller scope)
	if ! _apply_conflict_resolution "$target_path" "$force" "$description" "$fetch_dir"; then
		rm -rf "$fetch_dir"
		return 1
	fi

	if [[ "$dry_run" == true ]]; then
		log_info "DRY RUN - Would create:"
		echo "  .agents/${target_path}.md"
		echo "  Source: $url"
		echo "  Format: url"
		echo "  Content hash: ${content_hash:-<unavailable>}"
		rm -rf "$fetch_dir"
		return 0
	fi

	# Convert URL content to aidevops format
	local target_file=".agents/${target_path}.md"
	if ! _convert_url_to_skill "$fetch_file" "$target_file" "$skill_name" "$description" "$url"; then
		rm -rf "$fetch_dir"
		return 1
	fi

	# Finalize: security scan, register, cleanup
	if ! _finalize_import "$fetch_dir" "$skill_name" "$skip_security" \
		"$target_file" "$target_path" \
		"$url" ".agents/${target_path}.md" "url" "" \
		"added" "Imported from URL" \
		"$content_hash" "$resp_etag" "$resp_last_modified" "$fetch_dir"; then
		return 1
	fi

	log_success "Skill '$skill_name' imported from URL successfully"
	echo ""
	log_info "Run './setup.sh' to create symlinks for other AI assistants"
	log_info "Updates detected via content hash comparison (SHA-256)"
	if [[ -n "$resp_etag" || -n "$resp_last_modified" ]]; then
		log_info "HTTP caching headers captured for conditional requests (ETag/Last-Modified)"
	fi

	return 0
}

# Import a skill from ClawdHub registry
cmd_add_clawdhub() {
	local slug="$1"
	local custom_name="$2"
	local force="$3"
	local dry_run="$4"
	local skip_security="${5:-false}"

	if [[ -z "$slug" ]]; then
		log_error "ClawdHub slug required"
		return 1
	fi

	log_info "Importing from ClawdHub: $slug"

	# Get skill metadata from API
	local api_response
	api_response=$(curl -fsS --connect-timeout 10 --max-time 30 "${CLAWDHUB_API:-https://clawdhub.com/api/v1}/skills/${slug}") || {
		log_error "Failed to fetch skill info (HTTP/network) from ClawdHub API: $slug"
		return 1
	}

	if ! echo "$api_response" | jq -e . >/dev/null 2>&1; then
		log_error "ClawdHub API returned invalid JSON for skill: $slug"
		return 1
	fi

	# Extract metadata
	local display_name summary owner_handle version
	display_name=$(echo "$api_response" | jq -r '.skill.displayName // ""')
	summary=$(echo "$api_response" | jq -r '.skill.summary // ""')
	owner_handle=$(echo "$api_response" | jq -r '.owner.handle // ""')
	version=$(echo "$api_response" | jq -r '.latestVersion.version // ""')

	log_info "Found: $display_name v${version} by @${owner_handle}"

	# Determine skill name
	local skill_name
	if [[ -n "$custom_name" ]]; then
		skill_name=$(to_kebab_case "$custom_name")
	else
		skill_name=$(to_kebab_case "$slug")
	fi

	# Determine target path
	local target_path
	target_path=$(determine_target_path "$skill_name" "$summary" ".")
	log_info "Target path: .agents/$target_path"

	# Handle conflicts (may update skill_name/target_path in caller scope)
	if ! _apply_conflict_resolution "$target_path" "$force" "$summary" "."; then
		return 1
	fi

	if [[ "$dry_run" == true ]]; then
		log_info "DRY RUN - Would create:"
		echo "  .agents/${target_path}.md"
		return 0
	fi

	# Fetch and convert ClawdHub content
	local fetch_dir="${TMPDIR:-/tmp}/clawdhub-fetch/${slug}"
	local target_file=".agents/${target_path}.md"
	if ! _fetch_and_convert_clawdhub "$slug" "$fetch_dir" "$target_file" "$display_name" "$skill_name" "$summary" "$version"; then
		return 1
	fi

	# Finalize: security scan, register, cleanup
	local upstream_url="https://clawdhub.com/${owner_handle}/${slug}"
	if ! _finalize_import "$fetch_dir" "$skill_name" "$skip_security" \
		"$target_file" "$target_path" \
		"$upstream_url" ".agents/${target_path}.md" "clawdhub" "$version" \
		"added" "ClawdHub v${version} by @${owner_handle}" \
		"" "" "" "$fetch_dir"; then
		return 1
	fi

	log_success "Skill '$skill_name' imported from ClawdHub successfully"
	echo ""
	log_info "Run './setup.sh' to create symlinks for other AI assistants"

	return 0
}

cmd_list() {
	ensure_skill_sources

	echo ""
	echo "Imported Skills"
	echo "==============="
	echo ""

	if command -v jq &>/dev/null; then
		local count
		count=$(jq '.skills | length' "$SKILL_SOURCES")

		if [[ "$count" -eq 0 ]]; then
			echo "No skills imported yet."
			echo ""
			echo "Use: add-skill-helper.sh add <owner/repo>"
			return 0
		fi

		jq -r '.skills[] | "  \(.name)\n    Path: \(.local_path)\n    Source: \(.upstream_url)\n    Imported: \(.imported_at)\n"' "$SKILL_SOURCES"
	else
		cat "$SKILL_SOURCES"
	fi

	return 0
}

cmd_check_updates() {
	ensure_skill_sources

	log_info "Checking for upstream updates..."

	if ! command -v jq &>/dev/null; then
		log_error "jq is required for update checking"
		return 1
	fi

	local skills
	skills=$(jq -r '.skills[] | "\(.name)|\(.upstream_url)|\(.upstream_commit)"' "$SKILL_SOURCES")

	if [[ -z "$skills" ]]; then
		log_info "No imported skills to check"
		return 0
	fi

	local updates_available=false

	local name url commit owner repo
	while IFS='|' read -r name url commit; do
		# Skip ClawdHub skills — update checks not yet supported for clawdhub.com URLs
		if [[ "$url" == *clawdhub.com/* ]]; then
			log_info "Skipping ClawdHub skill ($name) — update checks not yet supported"
			continue
		fi

		# Extract owner/repo from URL
		local parsed
		parsed=$(parse_github_url "$url")
		IFS='|' read -r owner repo _ _ <<<"$parsed"

		if [[ -z "$owner" || -z "$repo" ]]; then
			log_warning "Could not parse URL for $name: $url"
			continue
		fi

		# Get latest commit from GitHub API
		local api_url="https://api.github.com/repos/$owner/$repo/commits?per_page=1"
		local api_response
		api_response=$(curl -s --connect-timeout 10 --max-time 30 "$api_url")

		# Check if response is an array (success) or object (error)
		local latest_commit
		if echo "$api_response" | jq -e 'type == "array"' >/dev/null 2>&1; then
			latest_commit=$(echo "$api_response" | jq -r '.[0].sha // empty')
		else
			# API returned an error object (rate limit, not found, etc.)
			latest_commit=""
		fi

		if [[ -z "$latest_commit" ]]; then
			log_warning "Could not fetch latest commit for $name"
			continue
		fi

		if [[ "$latest_commit" != "$commit" ]]; then
			updates_available=true
			echo -e "${YELLOW}UPDATE AVAILABLE${NC}: $name"
			echo "  Current: ${commit:0:7}"
			echo "  Latest:  ${latest_commit:0:7}"
			echo "  Run: aidevops skill update $name"
			echo ""
		else
			echo -e "${GREEN}Up to date${NC}: $name"
		fi
	done <<<"$skills"

	if [[ "$updates_available" == false ]]; then
		log_success "All skills are up to date"
	fi

	return 0
}

cmd_remove() {
	local name="$1"

	if [[ -z "$name" ]]; then
		log_error "Skill name required"
		return 1
	fi

	ensure_skill_sources

	if ! command -v jq &>/dev/null; then
		log_error "jq is required for skill removal"
		return 1
	fi

	# Find skill in registry
	local skill_path
	skill_path=$(jq -r --arg name "$name" '.skills[] | select(.name == $name) | .local_path' "$SKILL_SOURCES")

	if [[ -z "$skill_path" ]]; then
		log_error "Skill not found: $name"
		return 1
	fi

	log_info "Removing skill: $name"
	log_info "Path: $skill_path"

	# Remove files
	if [[ -f "$skill_path" ]]; then
		rm -f "$skill_path"
		log_success "Removed: $skill_path"
	fi

	# Remove directory if exists
	local dir_path="${skill_path%.md}"
	if [[ -d "$dir_path" ]]; then
		rm -rf "$dir_path"
		log_success "Removed: $dir_path/"
	fi

	# Remove from registry
	local tmp_file
	tmp_file=$(mktemp)
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "rm -f '${tmp_file}'"
	if ! jq --arg name "$name" '.skills = [.skills[] | select(.name != $name)]' "$SKILL_SOURCES" >"$tmp_file"; then
		log_error "Failed to process skill sources JSON. Remove aborted."
		rm -f "$tmp_file"
		return 1
	fi
	mv "$tmp_file" "$SKILL_SOURCES"

	log_success "Skill '$name' removed"

	return 0
}
