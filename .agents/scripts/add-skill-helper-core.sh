#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Add Skill Helper — Core Utilities
# =============================================================================
# Core utility functions for skill import: help text, format detection, parsing,
# name extraction, target path resolution, conflict checking, format conversion,
# and skill registration.
#
# Usage: source "${SCRIPT_DIR}/add-skill-helper-core.sh"
#
# Dependencies:
#   - shared-constants.sh (log_info, log_error, log_success, log_warning, etc.)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_ADD_SKILL_CORE_LIB_LOADED:-}" ]] && return 0
_ADD_SKILL_CORE_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# --- Functions ---

show_help() {
	cat <<'EOF'
Add External Skill Helper - Import skills from GitHub, ClawdHub, or URLs to aidevops

USAGE:
    add-skill-helper.sh <command> [options]

COMMANDS:
    add <url|owner/repo|clawdhub:slug>    Import a skill
    list                                   List all imported skills
    check-updates                          Check for upstream updates
    remove <name>                          Remove an imported skill
    help                                   Show this help message

OPTIONS:
    --name <name>           Override the skill name
    --force                 Overwrite existing skill without prompting
    --skip-security         Bypass security scan (use with caution)
    --dry-run               Show what would be done without making changes

EXAMPLES:
    # Import from GitHub shorthand
    add-skill-helper.sh add dmmulroy/cloudflare-skill

    # Import specific skill from multi-skill repo
    add-skill-helper.sh add anthropics/skills/pdf

    # Import with custom name
    add-skill-helper.sh add vercel-labs/agent-skills --name vercel-deploy

    # Import from ClawdHub (shorthand)
    add-skill-helper.sh add clawdhub:caldav-calendar

    # Import from ClawdHub (full URL)
    add-skill-helper.sh add https://clawdhub.com/Asleep123/caldav-calendar

    # Import from a raw URL (markdown file)
    add-skill-helper.sh add https://convos.org/skill.md --name convos

    # Import from any URL hosting a skill/markdown file
    add-skill-helper.sh add https://example.com/path/to/SKILL.md

    # Check all imported skills for updates
    add-skill-helper.sh check-updates

SUPPORTED SOURCES:
    - GitHub repos (owner/repo or full URL)
    - ClawdHub registry (clawdhub:slug or clawdhub.com URL)
    - Raw URLs (any URL ending in .md or serving markdown content)

SUPPORTED FORMATS:
    - SKILL.md (OpenSkills/Claude Code/ClawdHub format)
    - AGENTS.md (aidevops/Windsurf format)
    - .cursorrules (Cursor format)
    - Raw markdown files

The skill will be converted to aidevops format and placed in .agents/
with symlinks created to other AI assistant locations by setup.sh.
EOF
	return 0
}

# Ensure skill-sources.json exists
ensure_skill_sources() {
	if [[ ! -f "$SKILL_SOURCES" ]]; then
		mkdir -p "$(dirname "$SKILL_SOURCES")"
		# shellcheck disable=SC2016 # Single quotes intentional - $schema/$comment are JSON keys, not variables
		echo '{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$comment": "Registry of imported external skills with upstream tracking",
  "version": "1.0.0",
  "skills": []
}' >"$SKILL_SOURCES"
	fi
	return 0
}

# Parse GitHub URL or shorthand into components
parse_github_url() {
	local input="$1"
	local owner=""
	local repo=""
	local subpath=""

	# Remove https://github.com/ prefix if present
	input="${input#https://github.com/}"
	input="${input#http://github.com/}"
	input="${input#github.com/}"

	# Remove .git suffix if present
	input="${input%.git}"

	# Remove /tree/main or /tree/master if present (use bash instead of sed for portability)
	if [[ "$input" =~ ^(.+)/tree/(main|master)(/.*)?$ ]]; then
		input="${BASH_REMATCH[1]}${BASH_REMATCH[3]}"
	fi

	# Split by /
	local -a parts
	IFS='/' read -ra parts <<<"$input"

	if [[ ${#parts[@]} -ge 2 ]]; then
		owner="${parts[0]}"
		repo="${parts[1]}"

		# Everything after owner/repo is subpath
		if [[ ${#parts[@]} -gt 2 ]]; then
			# Join remaining parts with / using printf
			subpath=$(printf '%s/' "${parts[@]:2}")
			subpath="${subpath%/}" # Remove trailing slash
		fi
	fi

	echo "$owner|$repo|$subpath"
	return 0
}

# Detect skill format from directory contents
# Returns: format|skill_subdir (e.g., "skill-md-nested|skill/cloudflare")
detect_format() {
	local dir="$1"

	# Check for direct SKILL.md first
	if [[ -f "$dir/SKILL.md" ]]; then
		echo "skill-md|"
		return 0
	fi

	# Check for nested skill directory (e.g., skill/*/SKILL.md)
	local nested_skill
	nested_skill=$(find "$dir" -maxdepth 3 -name "SKILL.md" -type f 2>/dev/null | head -1)
	if [[ -n "$nested_skill" ]]; then
		local skill_subdir
		skill_subdir=$(dirname "$nested_skill")
		skill_subdir="${skill_subdir#"$dir/"}"
		echo "skill-md-nested|$skill_subdir"
		return 0
	fi

	if [[ -f "$dir/AGENTS.md" ]]; then
		echo "agents-md|"
	elif [[ -f "$dir/.cursorrules" ]]; then
		echo "cursorrules|"
	elif [[ -f "$dir/README.md" ]]; then
		echo "readme|"
	else
		# Look for any .md file
		local md_file
		md_file=$(find "$dir" -maxdepth 1 -name "*.md" -type f | head -1)
		if [[ -n "$md_file" ]]; then
			echo "markdown|"
		else
			echo "unknown|"
		fi
	fi
	return 0
}

# Extract skill name from SKILL.md frontmatter
extract_skill_name() {
	local file="$1"

	if [[ ! -f "$file" ]]; then
		return 1
	fi

	# Extract name from YAML frontmatter
	awk '
        /^---$/ { in_frontmatter = !in_frontmatter; next }
        in_frontmatter && /^name:/ {
            sub(/^name: */, "")
            gsub(/^["'"'"']|["'"'"']$/, "")
            print
            exit
        }
    ' "$file"
	return 0
}

# Extract description from SKILL.md frontmatter
extract_skill_description() {
	local file="$1"

	if [[ ! -f "$file" ]]; then
		return 1
	fi

	awk '
        /^---$/ { in_frontmatter = !in_frontmatter; next }
        in_frontmatter && /^description:/ {
            sub(/^description: */, "")
            gsub(/^["'"'"']|["'"'"']$/, "")
            print
            exit
        }
    ' "$file"
	return 0
}

# Convert skill name to kebab-case
to_kebab_case() {
	local name="$1"
	echo "$name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-\|-$//g'
	return 0
}

# Determine target path in .agents/ based on skill content
determine_target_path() {
	local skill_name="$1"
	local _description="$2" # Reserved for future category detection
	local source_dir="$3"

	# Analyze content to determine category
	local category="tools"

	# Check description and content for category hints
	local content=""
	if [[ -f "$source_dir/SKILL.md" ]]; then
		content=$(cat "$source_dir/SKILL.md")
	elif [[ -f "$source_dir/AGENTS.md" ]]; then
		content=$(cat "$source_dir/AGENTS.md")
	fi

	# Detect category from content (order matters - more specific patterns first)
	# Check skill name first for known services
	if [[ "$skill_name" == "cloudflare"* ]]; then
		category="services/hosting"
	elif echo "$content" | grep -qi "cloudflare workers\|cloudflare pages\|wrangler"; then
		category="services/hosting"
	# Architecture patterns (must come before generic patterns)
	elif echo "$content" | grep -qi "clean.architecture\|hexagonal\|ddd\|domain.driven\|ports.and.adapters\|onion.architecture\|cqrs\|event.sourcing"; then
		category="tools/architecture"
	elif echo "$content" | grep -qi "feature.sliced\|feature-sliced\|fsd.architecture\|slice.organization"; then
		category="tools/architecture"
	# Database and ORM patterns (must come before more generic service patterns)
	elif echo "$content" | grep -qi "postgresql\|postgres\|drizzle\|prisma\|typeorm\|sequelize\|knex\|database.orm"; then
		category="services/database"
	# Diagrams and visualization patterns (must come before more generic tool patterns)
	elif echo "$content" | grep -qi "mermaid\|flowchart\|sequence.diagram\|er.diagram\|uml"; then
		category="tools/diagrams"
	# Programming language patterns (must come before more generic tool patterns like browser)
	elif echo "$content" | grep -qi "javascript\|typescript\|es6\|es2020\|es2022\|es2024\|ecmascript\|modern.js"; then
		category="tools/programming"
	elif echo "$content" | grep -qi "browser\|playwright\|puppeteer\|selenium"; then
		category="tools/browser"
	elif echo "$content" | grep -qi "seo\|search.ranking\|keyword.research"; then
		category="seo"
	elif echo "$content" | grep -qi "git\|github\|gitlab"; then
		category="tools/git"
	elif echo "$content" | grep -qi "code.review\|lint\|quality"; then
		category="tools/code-review"
	elif echo "$content" | grep -qi "credential\|secret\|password\|vault"; then
		category="tools/credentials"
	elif echo "$content" | grep -qi "vercel\|coolify\|docker\|kubernetes"; then
		category="tools/deployment"
	elif echo "$content" | grep -qi "proxmox\|hypervisor\|virtualization\|vm.management"; then
		category="services/hosting"
	elif echo "$content" | grep -qi "calendar\|caldav\|ical\|scheduling"; then
		category="tools/productivity"
	elif echo "$content" | grep -qi "dns\|hosting\|domain"; then
		category="services/hosting"
	fi

	# Append -skill suffix to distinguish imported skills from native subagents
	# This enables: glob *-skill.md for imports, update checks, conflict avoidance
	echo "$category/${skill_name}-skill"
	return 0
}

# Check for conflicts with existing files
# Returns conflict info with type: NATIVE (our subagent) or IMPORTED (previous skill)
check_conflicts() {
	local target_path="$1"
	local agent_dir="$2"

	local full_path="$agent_dir/$target_path"
	local md_path="${full_path}.md"
	local dir_path="$full_path"

	local conflicts=()

	if [[ -f "$md_path" ]]; then
		if [[ "$md_path" == *-skill.md ]]; then
			conflicts+=("IMPORTED: $md_path")
		else
			conflicts+=("NATIVE: $md_path")
		fi
	fi

	if [[ -d "$dir_path" ]]; then
		if [[ "$dir_path" == *-skill ]]; then
			conflicts+=("IMPORTED: $dir_path/")
		else
			conflicts+=("NATIVE: $dir_path/")
		fi
	fi

	# Also check for native subagent without -skill suffix (same base name)
	local base_name="${target_path%-skill}"
	local native_md="${agent_dir}/${base_name}.md"
	if [[ "$target_path" == *-skill && -f "$native_md" ]]; then
		# Native subagent exists with same base name - not a conflict since
		# -skill suffix differentiates, but inform the user
		conflicts+=("INFO: Native subagent exists at $native_md (no conflict, -skill suffix differentiates)")
	fi

	if [[ ${#conflicts[@]} -gt 0 ]]; then
		printf '%s\n' "${conflicts[@]}"
		return 1
	fi

	return 0
}

# Convert SKILL.md to aidevops format
convert_skill_md() {
	local source_file="$1"
	local target_file="$2"
	local skill_name="$3"

	# Read source content
	local content
	content=$(cat "$source_file")

	# Extract frontmatter
	local name
	local description
	name=$(extract_skill_name "$source_file")
	description=$(extract_skill_description "$source_file")

	# Escape YAML special characters in description
	local safe_description
	safe_description=$(printf '%s' "${description:-Imported skill}" | sed 's/\\/\\\\/g; s/"/\\"/g; s/:/: /g; s/^- /\\- /')

	# Escape name for markdown heading
	local safe_name
	safe_name=$(printf '%s' "${name:-$skill_name}" | sed 's/\\/\\\\/g')

	# Create aidevops-style header with properly quoted description
	cat >"$target_file" <<EOF
---
description: "${safe_description}"
mode: subagent
imported_from: external
---
# ${safe_name}

EOF

	# Append content after frontmatter
	awk '
        BEGIN { in_frontmatter = 0; after_frontmatter = 0 }
        /^---$/ { 
            if (!in_frontmatter) { in_frontmatter = 1; next }
            else { in_frontmatter = 0; after_frontmatter = 1; next }
        }
        after_frontmatter { print }
    ' "$source_file" >>"$target_file"

	return 0
}

# Register skill in skill-sources.json
# Args: name upstream_url local_path format commit merge_strategy notes [upstream_hash] [upstream_etag] [upstream_last_modified]
register_skill() {
	local name="$1"
	local upstream_url="$2"
	local local_path="$3"
	local format="$4"
	local commit="${5:-}"
	local merge_strategy="${6:-added}"
	local notes="${7:-}"
	local upstream_hash="${8:-}"
	local upstream_etag="${9:-}"
	local upstream_last_modified="${10:-}"

	ensure_skill_sources

	# jq is required for reliable JSON manipulation
	if ! command -v jq &>/dev/null; then
		log_error "jq is required to update $SKILL_SOURCES"
		log_info "Install with: brew install jq (macOS) or apt install jq (Linux)"
		return 1
	fi

	# Check for existing entry and remove it (update scenario)
	local existing
	existing=$(jq -r --arg name "$name" '.skills[] | select(.name == $name) | .name' "$SKILL_SOURCES" 2>/dev/null || echo "")
	if [[ -n "$existing" ]]; then
		log_info "Updating existing skill registration: $name"
		local tmp_file
		tmp_file=$(mktemp)
		_save_cleanup_scope
		trap '_run_cleanups' RETURN
		push_cleanup "rm -f '${tmp_file}'"
		if ! jq --arg name "$name" '.skills = [.skills[] | select(.name != $name)]' "$SKILL_SOURCES" >"$tmp_file"; then
			log_error "Failed to process skill sources JSON. Update aborted."
			rm -f "$tmp_file"
			return 1
		fi
		mv "$tmp_file" "$SKILL_SOURCES"
	fi

	local timestamp
	timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

	# Create new skill entry using jq for proper JSON escaping
	# Include upstream_hash, upstream_etag, upstream_last_modified for URL-sourced skills (t1415.2, t1415.3)
	local new_entry
	new_entry=$(jq -n \
		--arg name "$name" \
		--arg upstream_url "$upstream_url" \
		--arg upstream_commit "$commit" \
		--arg local_path "$local_path" \
		--arg format_detected "$format" \
		--arg imported_at "$timestamp" \
		--arg last_checked "$timestamp" \
		--arg merge_strategy "$merge_strategy" \
		--arg notes "$notes" \
		--arg upstream_hash "$upstream_hash" \
		--arg upstream_etag "$upstream_etag" \
		--arg upstream_last_modified "$upstream_last_modified" \
		'{
            name: $name,
            upstream_url: $upstream_url,
            upstream_commit: $upstream_commit,
            local_path: $local_path,
            format_detected: $format_detected,
            imported_at: $imported_at,
            last_checked: $last_checked,
            merge_strategy: $merge_strategy,
            notes: $notes
        } + (if $upstream_hash != "" then { upstream_hash: $upstream_hash } else {} end)
          + (if $upstream_etag != "" then { upstream_etag: $upstream_etag } else {} end)
          + (if $upstream_last_modified != "" then { upstream_last_modified: $upstream_last_modified } else {} end)')

	local tmp_file
	tmp_file=$(mktemp)
	jq --argjson entry "$new_entry" '.skills += [$entry]' "$SKILL_SOURCES" >"$tmp_file" && mv "$tmp_file" "$SKILL_SOURCES"
	rm -f "$tmp_file"

	return 0
}
