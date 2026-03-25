#!/usr/bin/env bash
# =============================================================================
# Add External Skill Helper
# =============================================================================
# Import external skills from GitHub repos, ClawdHub, or raw URLs, convert to
# aidevops format, handle conflicts, and track upstream sources for update detection.
#
# Usage:
#   add-skill-helper.sh add <url|owner/repo|clawdhub:slug> [--name <name>] [--force] [--skip-security]
#   add-skill-helper.sh list
#   add-skill-helper.sh check-updates
#   add-skill-helper.sh remove <name>
#   add-skill-helper.sh help
#
# Examples:
#   add-skill-helper.sh add dmmulroy/cloudflare-skill
#   add-skill-helper.sh add https://github.com/anthropics/skills/pdf
#   add-skill-helper.sh add vercel-labs/agent-skills --name vercel
#   add-skill-helper.sh add clawdhub:caldav-calendar
#   add-skill-helper.sh add https://clawdhub.com/Asleep123/caldav-calendar
#   add-skill-helper.sh add https://convos.org/skill.md --name convos
#   add-skill-helper.sh check-updates
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# Configuration
AGENTS_DIR="${AIDEVOPS_AGENTS_DIR:-$HOME/.aidevops/agents}"
SKILL_SOURCES="${AGENTS_DIR}/configs/skill-sources.json"
TEMP_DIR="${TMPDIR:-/tmp}/aidevops-skill-import"
SCAN_RESULTS_FILE=".agents/SKILL-SCAN-RESULTS.md"

# =============================================================================
# Helper Functions
# =============================================================================

# Logging: uses shared log_* from shared-constants.sh with add-skill prefix
# shellcheck disable=SC2034  # Used by shared-constants.sh log_* functions
LOG_PREFIX="add-skill"

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

# =============================================================================
# Security Scanning
# =============================================================================

# Scan a skill directory for security threats using Cisco Skill Scanner
# Returns: 0 = safe or scanner not available, 1 = blocked (CRITICAL/HIGH found)
scan_skill_security() {
	local scan_path="$1"
	local skill_name="$2"
	local skip_security="${3:-false}"

	# Determine scanner command
	local scanner_cmd=""
	if command -v skill-scanner &>/dev/null; then
		scanner_cmd="skill-scanner"
	elif command -v uvx &>/dev/null; then
		scanner_cmd="uvx cisco-ai-skill-scanner"
	elif command -v pipx &>/dev/null; then
		scanner_cmd="pipx run cisco-ai-skill-scanner"
	else
		log_info "Skill Scanner not installed (skipping security scan)"
		log_info "Install with: uv tool install cisco-ai-skill-scanner"
		return 0
	fi

	log_info "Running security scan on '$skill_name'..."

	local scan_output
	scan_output=$($scanner_cmd scan "$scan_path" --format json 2>/dev/null) || true

	if [[ -z "$scan_output" ]]; then
		log_success "Security scan: SAFE (no findings)"
		log_skill_scan_result "$skill_name" "import" "0" "0" "0" "SAFE"
		return 0
	fi

	local findings max_severity critical_count high_count medium_count
	findings=$(echo "$scan_output" | jq -r '.total_findings // 0' 2>/dev/null || echo "0")
	max_severity=$(echo "$scan_output" | jq -r '.max_severity // "SAFE"' 2>/dev/null || echo "SAFE")
	critical_count=$(echo "$scan_output" | jq -r '.findings | map(select(.severity == "CRITICAL")) | length' 2>/dev/null || echo "0")
	high_count=$(echo "$scan_output" | jq -r '.findings | map(select(.severity == "HIGH")) | length' 2>/dev/null || echo "0")
	medium_count=$(echo "$scan_output" | jq -r '.findings | map(select(.severity == "MEDIUM")) | length' 2>/dev/null || echo "0")

	if [[ "$findings" -eq 0 ]]; then
		log_success "Security scan: SAFE (no findings)"
		log_skill_scan_result "$skill_name" "import" "0" "0" "0" "SAFE"
		return 0
	fi

	# Show findings summary
	echo ""
	echo -e "${YELLOW}Security scan found $findings issue(s) (max severity: $max_severity):${NC}"

	# Show individual findings
	echo "$scan_output" | jq -r '.findings[]? | "  [\(.severity)] \(.rule_id): \(.description // "No description")"' 2>/dev/null || true
	echo ""

	# Block on CRITICAL/HIGH unless --skip-security
	if [[ "$critical_count" -gt 0 || "$high_count" -gt 0 ]]; then
		_scan_skill_handle_critical "$skill_name" "$critical_count" "$high_count" "$medium_count" "$max_severity" "$skip_security"
		return $?
	fi

	# MEDIUM/LOW findings: warn but allow
	log_warning "Security scan found $findings issue(s) (max: $max_severity) - review recommended"
	log_skill_scan_result "$skill_name" "import" "$critical_count" "$high_count" "$medium_count" "$max_severity"
	return 0
}

# Handle CRITICAL/HIGH security findings: prompt user or block in non-interactive mode.
# Args: $1=skill_name $2=critical_count $3=high_count $4=medium_count $5=max_severity $6=skip_security
# Returns: 0=proceed, 1=blocked
_scan_skill_handle_critical() {
	local skill_name="$1"
	local critical_count="$2"
	local high_count="$3"
	local medium_count="$4"
	local max_severity="$5"
	local skip_security="$6"

	if [[ "$skip_security" == true ]]; then
		log_warning "CRITICAL/HIGH findings detected but --skip-security specified, proceeding"
		log_skill_scan_result "$skill_name" "import (--skip-security)" "$critical_count" "$high_count" "$medium_count" "$max_severity"
		return 0
	fi

	echo -e "${RED}BLOCKED: $critical_count CRITICAL and $high_count HIGH severity findings.${NC}"
	echo ""
	echo "This skill may contain:"
	echo "  - Prompt injection or jailbreak instructions"
	echo "  - Data exfiltration patterns"
	echo "  - Command injection or malicious code"
	echo "  - Hardcoded secrets or credentials"
	echo ""
	echo "Options:"
	echo "  1. Cancel import (recommended)"
	echo "  2. Import anyway (--skip-security)"
	echo ""

	# In non-interactive mode (piped), block by default
	if [[ ! -t 0 ]]; then
		log_error "Import blocked due to security findings (use --skip-security to override)"
		return 1
	fi

	local choice
	read -rp "Choose option [1-2]: " choice
	case "$choice" in
	2)
		log_warning "Proceeding despite security findings"
		log_skill_scan_result "$skill_name" "import (user override)" "$critical_count" "$high_count" "$medium_count" "$max_severity"
		return 0
		;;
	*)
		log_error "Import cancelled due to security findings"
		log_skill_scan_result "$skill_name" "import BLOCKED" "$critical_count" "$high_count" "$medium_count" "$max_severity"
		return 1
		;;
	esac
}

# Run VirusTotal scan on skill files and referenced domains
# Returns: 0 (always, as VT scans are advisory; Cisco scanner is the gate)
scan_skill_virustotal() {
	local scan_path="$1"
	local skill_name="$2"
	local skip_security="${3:-false}"

	if [[ "$skip_security" == true ]]; then
		return 0
	fi

	# Check if virustotal-helper.sh is available
	local vt_helper=""
	vt_helper="$(dirname "$0")/virustotal-helper.sh"
	if [[ ! -x "$vt_helper" ]]; then
		return 0
	fi

	# Check if VT API key is configured (don't fail if not)
	if ! "$vt_helper" status 2>/dev/null | grep -q "API key configured"; then
		log_info "VirusTotal: API key not configured (skipping VT scan)"
		return 0
	fi

	log_info "Running VirusTotal scan on '$skill_name'..."

	if ! "$vt_helper" scan-skill "$scan_path" --quiet; then
		log_warning "VirusTotal flagged potential threats in '$skill_name'"
		log_info "Run: $vt_helper scan-skill '$scan_path' for details"
		# VT findings are advisory, not blocking (Cisco scanner is the gate)
		return 0
	fi

	log_success "VirusTotal: No threats detected"
	return 0
}

# Log a single skill scan result to SKILL-SCAN-RESULTS.md
# Args: skill_name action critical_count high_count medium_count max_severity
log_skill_scan_result() {
	local skill_name="$1"
	local action="$2"
	local critical="${3:-0}"
	local high="${4:-0}"
	local medium="${5:-0}"
	local max_severity="${6:-SAFE}"

	local repo_root=""
	repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")

	if [[ -z "$repo_root" || ! -f "${repo_root}/${SCAN_RESULTS_FILE}" ]]; then
		return 0
	fi

	local scan_date
	scan_date=$(date -u +"%Y-%m-%d")
	local safe="1"

	if [[ "$critical" -gt 0 || "$high" -gt 0 ]]; then
		safe="0"
	fi

	local notes="Skill ${action}: ${skill_name} (${max_severity})"
	echo "| ${scan_date} | 1 | ${safe} | ${critical} | ${high} | ${medium} | ${notes} |" >>"${repo_root}/${SCAN_RESULTS_FILE}"

	return 0
}

# =============================================================================
# Shared Import Helpers (used by cmd_add, cmd_add_url, cmd_add_clawdhub)
# =============================================================================

# Handle conflict resolution for all import paths.
# Sets skill_name and target_path in the caller's scope if the user renames.
# Args: target_path force description source_dir
# Returns: 0 = proceed, 1 = cancelled or non-interactive block
_handle_conflicts() {
	local target_path_arg="$1"
	local force="$2"
	local description="$3"
	local source_dir="$4"

	local conflicts
	conflicts=$(check_conflicts "$target_path_arg" ".agent") || true
	if [[ -z "$conflicts" ]]; then
		return 0
	fi

	local blocking_conflicts
	blocking_conflicts=$(echo "$conflicts" | grep -v "^INFO:" || true)
	local info_lines
	info_lines=$(echo "$conflicts" | grep "^INFO:" || true)

	# Show info lines (native subagent coexistence)
	if [[ -n "$info_lines" ]]; then
		echo "$info_lines" | while read -r info; do
			log_info "${info#INFO: }"
		done
	fi

	# No blocking conflicts — proceed (reset rename vars)
	if [[ -z "$blocking_conflicts" || "$force" == true ]]; then
		_conflict_new_skill_name=""
		_conflict_new_target_path=""
		return 0
	fi

	# Determine conflict type for better messaging
	if echo "$blocking_conflicts" | grep -q "^NATIVE:"; then
		log_warning "Conflicts with native aidevops subagent(s):"
		echo "$blocking_conflicts" | while read -r conflict; do
			echo "  - ${conflict#NATIVE: }"
		done
		echo ""
		echo "The -skill suffix should prevent this. If you see this,"
		echo "the imported skill has the same name as a native subagent."
		echo ""
	elif echo "$blocking_conflicts" | grep -q "^IMPORTED:"; then
		log_warning "Conflicts with previously imported skill(s):"
		echo "$blocking_conflicts" | while read -r conflict; do
			echo "  - ${conflict#IMPORTED: }"
		done
		echo ""
	else
		log_warning "Conflicts detected:"
		echo "$blocking_conflicts" | while read -r conflict; do
			echo "  - ${conflict#*: }"
		done
		echo ""
	fi

	# In non-interactive mode, block
	if [[ ! -t 0 ]]; then
		log_error "Conflicts detected in non-interactive mode (use --force to override)"
		return 1
	fi

	echo "Options:"
	echo "  1. Replace (overwrite existing)"
	echo "  2. Separate (use different name)"
	echo "  3. Skip (cancel import)"
	echo ""
	read -rp "Choose option [1-3]: " choice

	local new_name
	case "$choice" in
	1) log_info "Replacing existing..." ;;
	2)
		read -rp "Enter new name: " new_name
		# Update caller's variables via nameref-free pattern (bash 3.2 compat)
		_conflict_new_skill_name=$(to_kebab_case "$new_name")
		_conflict_new_target_path=$(determine_target_path "$_conflict_new_skill_name" "$description" "$source_dir")
		;;
	3 | *)
		log_info "Import cancelled"
		return 1
		;;
	esac

	return 0
}

# Handle conflicts and apply any rename. Updates skill_name and target_path in caller scope.
# Args: target_path force description source_dir
# Returns: 0 = proceed, 1 = cancelled
_apply_conflict_resolution() {
	local target_path_arg="$1"
	local force="$2"
	local description="$3"
	local source_dir="$4"

	_conflict_new_skill_name=""
	_conflict_new_target_path=""
	if ! _handle_conflicts "$target_path_arg" "$force" "$description" "$source_dir"; then
		return 1
	fi
	# Apply rename if user chose option 2
	if [[ -n "$_conflict_new_skill_name" ]]; then
		skill_name="$_conflict_new_skill_name"
		target_path="$_conflict_new_target_path"
	fi
	return 0
}

# Run security scans, register skill, and clean up temp directory.
# Args: scan_dir skill_name skip_security target_file target_path
#       upstream_url local_path format commit merge_strategy notes
#       [upstream_hash] [upstream_etag] [upstream_last_modified] [cleanup_dir]
_finalize_import() {
	local scan_dir="$1"
	local skill_name="$2"
	local skip_security="$3"
	local target_file="$4"
	local target_path="$5"
	local upstream_url="$6"
	local local_path="$7"
	local format="$8"
	local commit="${9:-}"
	local merge_strategy="${10:-added}"
	local notes="${11:-}"
	local upstream_hash="${12:-}"
	local upstream_etag="${13:-}"
	local upstream_last_modified="${14:-}"
	local cleanup_dir="${15:-}"

	# Security scan before registration
	if ! scan_skill_security "$scan_dir" "$skill_name" "$skip_security"; then
		rm -f "$target_file"
		local skill_resource_dir=".agents/${target_path}"
		[[ -d "$skill_resource_dir" ]] && rm -rf "$skill_resource_dir"
		[[ -n "$cleanup_dir" ]] && rm -rf "$cleanup_dir"
		return 1
	fi

	# VirusTotal scan (advisory, non-blocking)
	scan_skill_virustotal "$scan_dir" "$skill_name" "$skip_security"

	# Register in skill-sources.json
	register_skill "$skill_name" "$upstream_url" "$local_path" "$format" \
		"$commit" "$merge_strategy" "$notes" \
		"$upstream_hash" "$upstream_etag" "$upstream_last_modified"

	# Cleanup temp directory
	[[ -n "$cleanup_dir" ]] && rm -rf "$cleanup_dir"

	return 0
}

# Fetch content from a URL with validation.
# Sets in caller scope: fetch_file, header_file, resp_etag, resp_last_modified, content_hash
# Args: url fetch_dir
# Returns: 0 = success, 1 = failure (fetch_dir cleaned up on failure)
_fetch_url_content() {
	local url="$1"
	local fetch_dir="$2"

	fetch_file="$fetch_dir/fetched-skill.md"
	header_file="$fetch_dir/response-headers.txt"

	local http_code=""
	http_code=$(curl -sS -L --connect-timeout 15 --max-time 60 \
		-o "$fetch_file" -D "$header_file" -w "%{http_code}" \
		-H "User-Agent: aidevops-skill-importer/1.0" \
		"$url" 2>/dev/null) || true

	if [[ -z "$http_code" || "$http_code" == "000" ]]; then
		log_error "Failed to connect to URL (network error or DNS failure): $url"
		rm -rf "$fetch_dir"
		return 1
	fi

	if [[ "$http_code" != "200" ]]; then
		log_error "Failed to fetch URL (HTTP $http_code): $url"
		rm -rf "$fetch_dir"
		return 1
	fi

	if [[ ! -s "$fetch_file" ]]; then
		log_error "Fetched content is empty: $url"
		rm -rf "$fetch_dir"
		return 1
	fi

	# Extract ETag and Last-Modified from response headers for caching (t1415.3)
	resp_etag=""
	resp_last_modified=""
	if [[ -f "$header_file" ]]; then
		resp_etag=$(grep -i '^etag:' "$header_file" | tail -1 | sed 's/^[Ee][Tt][Aa][Gg]: *//; s/\r$//')
		resp_last_modified=$(grep -i '^last-modified:' "$header_file" | tail -1 | sed 's/^[Ll][Aa][Ss][Tt]-[Mm][Oo][Dd][Ii][Ff][Ii][Ee][Dd]: *//; s/\r$//')
	fi

	# Validate that the content looks like markdown/text (not HTML error page, binary, etc.)
	local content_head
	content_head=$(head -c 512 "$fetch_file" | tr '[:upper:]' '[:lower:]')
	if [[ "$content_head" =~ ^\<\!doctype || "$content_head" =~ ^\<html ]]; then
		log_error "URL returned HTML instead of markdown. Ensure the URL points to raw content."
		log_info "Hint: For GitHub files, use the raw URL (raw.githubusercontent.com)"
		rm -rf "$fetch_dir"
		return 1
	fi

	# Compute SHA-256 content hash
	content_hash=""
	if command -v shasum &>/dev/null; then
		content_hash=$(shasum -a 256 "$fetch_file" | cut -d' ' -f1)
	elif command -v sha256sum &>/dev/null; then
		content_hash=$(sha256sum "$fetch_file" | cut -d' ' -f1)
	else
		log_warning "Neither shasum nor sha256sum available, skipping content hash"
	fi

	log_info "Content hash (SHA-256): ${content_hash:0:16}..."

	return 0
}

# Resolve skill name from custom name, frontmatter, or URL/repo fallback.
# Args: custom_name source_file fallback_name [url_for_domain_fallback]
# Prints: resolved kebab-case skill name
_resolve_skill_name() {
	local custom_name="$1"
	local source_file="$2"
	local fallback_name="$3"
	local url_for_domain="${4:-}"

	if [[ -n "$custom_name" ]]; then
		to_kebab_case "$custom_name"
		return 0
	fi

	# Try to extract name from frontmatter
	local extracted_name=""
	if [[ -f "$source_file" ]]; then
		extracted_name=$(extract_skill_name "$source_file")
	fi

	if [[ -n "$extracted_name" ]]; then
		to_kebab_case "$extracted_name"
		return 0
	fi

	# URL domain fallback: if basename is generic, use domain name
	if [[ -n "$url_for_domain" ]]; then
		local url_basename
		url_basename=$(basename "$url_for_domain")
		url_basename="${url_basename%.md}"
		if [[ "$url_basename" =~ ^(skill|SKILL|index|README|readme)$ ]]; then
			local domain
			domain=$(echo "$url_for_domain" | sed -E 's|^https?://([^/]+).*|\1|' | sed 's/^www\.//')
			to_kebab_case "${domain%%.*}"
			return 0
		fi
		to_kebab_case "$url_basename"
		return 0
	fi

	to_kebab_case "$fallback_name"
	return 0
}

# Convert source files to aidevops format and copy to target location.
# Args: format source_dir skill_source_dir target_file skill_name target_path
_convert_and_install_files() {
	local format="$1"
	local source_dir="$2"
	local skill_source_dir="$3"
	local target_file="$4"
	local skill_name="$5"
	local target_path="$6"

	# Create target directory
	local target_dir
	target_dir=".agents/$(dirname "$target_path")"
	mkdir -p "$target_dir"

	case "$format" in
	skill-md | skill-md-nested)
		convert_skill_md "$skill_source_dir/SKILL.md" "$target_file" "$skill_name"
		;;
	agents-md)
		cp "$source_dir/AGENTS.md" "$target_file"
		;;
	cursorrules)
		{
			echo "---"
			echo "description: Imported from .cursorrules"
			echo "mode: subagent"
			echo "imported_from: cursorrules"
			echo "---"
			echo "# $skill_name"
			echo ""
			cat "$source_dir/.cursorrules"
		} >"$target_file"
		;;
	*)
		local md_file
		md_file=$(find "$source_dir" -maxdepth 1 -name "*.md" -type f | head -1)
		if [[ -n "$md_file" ]]; then
			cp "$md_file" "$target_file"
		else
			log_error "No suitable files found to import"
			return 1
		fi
		;;
	esac

	log_success "Created: $target_file"

	# Copy additional resources (scripts, references, assets)
	local resource_dir
	for resource_dir in scripts references assets; do
		if [[ -d "$skill_source_dir/$resource_dir" ]]; then
			local target_resource_dir=".agents/${target_path}/$resource_dir"
			mkdir -p "$target_resource_dir"
			cp -r "$skill_source_dir/$resource_dir/"* "$target_resource_dir/" 2>/dev/null || true
			log_success "Copied: $resource_dir/"
		fi
	done

	return 0
}

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
	local opt
	while [[ $# -gt 0 ]]; do
		opt="$1"
		case "$opt" in
		--name)
			_add_custom_name="$2"
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

# =============================================================================
# Main
# =============================================================================

main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	add)
		if [[ $# -lt 1 ]]; then
			log_error "URL or owner/repo required"
			echo "Usage: add-skill-helper.sh add <url|owner/repo> [--name <name>] [--force] [--skip-security]"
			return 1
		fi
		cmd_add "$@"
		;;
	list)
		cmd_list
		;;
	check-updates | updates)
		cmd_check_updates
		;;
	remove | rm)
		cmd_remove "$@"
		;;
	help | --help | -h)
		show_help
		;;
	*)
		log_error "Unknown command: $command"
		show_help
		return 1
		;;
	esac
}

main "$@"
